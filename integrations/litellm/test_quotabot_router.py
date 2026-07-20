import asyncio
import json
import os
import tempfile
import unittest
import unittest.mock
import urllib.request
import warnings
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock, Thread

from quotabot_router import (
    AgentRule,
    Candidate,
    Policy,
    QuotabotRouter,
    UnsafeRouteError,
    _LeaseChoice,
    _NO_REDIRECT_OPENER,
    _best_ranked_candidate,
    _candidate_for_reserved_target,
    _is_loopback_url,
    _load_local_http_token,
    _metric_info_for_candidate,
)


class _Key:
    key_alias = "trusted-agent"
    user_id = None


async def _unit_reserve_remote(
    router,
    candidates,
    ranked,
    floor,
    prior_decision_id,
):
    remote = _best_ranked_candidate(candidates, ranked, floor)
    if remote is None:
        return None
    candidate, info = remote
    decision_id = prior_decision_id
    return _LeaseChoice(
        candidate,
        _metric_info_for_candidate(info, ranked, candidate),
        "unit-test-lease",
        decision_id,
    )


async def _unit_release_route_lease(router, route_meta):
    return None


class RouterTests(unittest.TestCase):
    def setUp(self):
        self.reserve_patch = unittest.mock.patch.object(
            QuotabotRouter,
            "_reserve_remote",
            _unit_reserve_remote,
        )
        self.release_patch = unittest.mock.patch.object(
            QuotabotRouter,
            "_release_route_lease",
            _unit_release_route_lease,
        )
        self.reserve_patch.start()
        self.release_patch.start()
        self.addCleanup(self.reserve_patch.stop)
        self.addCleanup(self.release_patch.stop)

    def test_shipped_proxy_example_requires_auth_and_loopback(self):
        root = Path(__file__).resolve().parent
        config = (root / "config.example.yaml").read_text(encoding="utf-8")
        readme = (root / "README.md").read_text(encoding="utf-8")

        self.assertIn("master_key: os.environ/LITELLM_MASTER_KEY", config)
        self.assertIn("litellm --config config.yaml --host 127.0.0.1", config)
        self.assertIn("litellm --config config.yaml --host 127.0.0.1", readme)
        self.assertIn("Authorization: Bearer $LITELLM_MASTER_KEY", readme)
        self.assertNotIn("\n   litellm --config config.yaml\n", readme)

    def test_key_alias_wins_over_client_metadata(self):
        data = {"metadata": {"agent": "spoofed-agent"}}
        self.assertEqual(QuotabotRouter._agent_id(data, _Key()), "trusted-agent")

    def test_client_metadata_does_not_select_agent_rules_without_key_identity(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-sonnet",
                        provider="claude",
                        spend="quota_plan",
                    )
                ]
            },
            agents={"spoofed-agent": AgentRule(pin="grok-fast")},
            block_unsafe_passthrough=False,
        )
        chosen = asyncio.run(
            router._route("frontier", {"metadata": {"agent": "spoofed-agent"}}, None)
        )
        self.assertEqual(chosen, "frontier")

    def test_trusted_pin_requires_safe_spend_class(self):
        router = QuotabotRouter()
        router.policy = Policy(
            agents={
                "trusted-agent": AgentRule(
                    pin="claude-subscription",
                    pin_spend="quota_plan",
                    pin_overages_disabled=True,
                )
            }
        )

        chosen = asyncio.run(router._route("frontier", {}, _Key()))

        self.assertEqual(chosen, "claude-subscription")

    def test_paid_api_pin_fails_closed_by_default(self):
        router = QuotabotRouter()
        router.policy = Policy(
            agents={
                "trusted-agent": AgentRule(
                    pin="xai-api",
                    pin_spend="paid_api",
                )
            }
        )

        with self.assertRaises(UnsafeRouteError):
            asyncio.run(router._route("frontier", {}, _Key()))

    def test_local_first_policy_stays_local(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "cheap-bulk": [
                    Candidate(deployment="ollama-qwen", local=True),
                    Candidate(deployment="claude-sonnet", provider="claude"),
                ]
            }
        )

        async def availability():
            return {
                "claude": {
                    "provider": "claude",
                    "available": True,
                    "headroom_percent": 90,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("cheap-bulk", {}, None))
        self.assertEqual(chosen, "ollama-qwen")

    def test_quota_candidate_marks_provider_account_for_metrics(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-sonnet",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ]
            }
        )

        async def availability():
            return {
                "claude": {
                    "provider": "claude",
                    "account": "work@example.com",
                    "available": True,
                    "headroom_percent": 90,
                }
            }

        data = {}
        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", data, None))
        self.assertEqual(chosen, "claude-sonnet")
        self.assertEqual(data["metadata"]["quotabot_spend"], "quota_plan")
        self.assertEqual(data["metadata"]["quotabot_provider"], "claude")
        self.assertEqual(data["metadata"]["quotabot_account"], "work@example.com")

    def test_quota_candidates_follow_quotabot_ranking(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-sonnet",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    ),
                    Candidate(
                        deployment="codex-high",
                        provider="codex",
                        spend="quota_plan",
                        overages_disabled=True,
                    ),
                ]
            }
        )

        async def availability():
            return [
                {
                    "provider": "codex",
                    "available": True,
                    "headroom_percent": 60,
                    "effective_headroom_percent": 60,
                },
                {
                    "provider": "claude",
                    "available": True,
                    "headroom_percent": 90,
                    "effective_headroom_percent": 10,
                    "pipe_discount_percent": 80,
                },
            ]

        data = {}
        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", data, None))
        self.assertEqual(chosen, "codex-high")
        self.assertEqual(data["metadata"]["quotabot_provider"], "codex")

    def test_ambiguous_provider_accounts_are_not_guessed_for_metrics(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-sonnet",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ]
            }
        )

        async def availability():
            return [
                {
                    "provider": "claude",
                    "account": "work@example.com",
                    "available": True,
                    "effective_headroom_percent": 80,
                },
                {
                    "provider": "claude",
                    "account": "home@example.com",
                    "available": True,
                    "effective_headroom_percent": 70,
                },
            ]

        data = {}
        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", data, None))
        self.assertEqual(chosen, "claude-sonnet")
        self.assertEqual(data["metadata"]["quotabot_provider"], "claude")
        self.assertNotIn("quotabot_account", data["metadata"])

    def test_candidate_account_matches_ranked_account(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-home",
                        provider="claude",
                        account="home@example.com",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ]
            }
        )

        async def availability():
            return [
                {
                    "provider": "claude",
                    "account": "work@example.com",
                    "available": True,
                    "effective_headroom_percent": 90,
                },
                {
                    "provider": "claude",
                    "account": "home@example.com",
                    "available": True,
                    "effective_headroom_percent": 70,
                },
            ]

        data = {}
        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", data, None))
        self.assertEqual(chosen, "claude-home")
        self.assertEqual(data["metadata"]["quotabot_account"], "home@example.com")

    def test_paid_api_candidates_are_skipped_by_default(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(deployment="xai-api", provider="grok", spend="paid_api"),
                    Candidate(deployment="ollama-qwen", local=True),
                ]
            }
        )

        async def availability():
            return {
                "grok": {
                    "provider": "grok",
                    "available": True,
                    "headroom_percent": 99,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", {}, None))
        self.assertEqual(chosen, "ollama-qwen")

    def test_managed_model_with_no_candidates_fails_closed(self):
        # A logical model declared in the policy but with an empty candidate
        # list is managed: it must fail closed, not fall through to the caller's
        # original (possibly paid) model.
        router = QuotabotRouter()
        router.policy = Policy(models={"frontier": []})
        with self.assertRaises(UnsafeRouteError):
            asyncio.run(router._route("frontier", {}, None))

    def test_malformed_policy_fails_closed_through_real_hook(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.yaml"
            path.write_text(
                """
models:
  frontier:
    candidates:
      - provider: claude
        spend: quota_plan
""",
                encoding="utf-8",
            )
            router = QuotabotRouter(str(path))

            data = {"model": "frontier"}
            with self.assertRaisesRegex(
                UnsafeRouteError,
                "routing policy could not be loaded safely",
            ):
                asyncio.run(router.async_pre_call_hook(None, None, data, "completion"))

        self.assertEqual(data, {"model": "frontier"})

    def test_explicitly_missing_policy_fails_closed_through_real_hook(self):
        with tempfile.TemporaryDirectory() as tmp:
            router = QuotabotRouter(str(Path(tmp) / "missing-policy.yaml"))
            with self.assertRaisesRegex(
                UnsafeRouteError,
                "routing policy could not be loaded safely",
            ):
                asyncio.run(
                    router.async_pre_call_hook(
                        None,
                        None,
                        {"model": "frontier"},
                        "completion",
                    )
                )

    def test_unmanaged_model_passes_through(self):
        # A model absent from the policy is not managed and passes through.
        router = QuotabotRouter()
        router.policy = Policy(models={"frontier": []})
        chosen = asyncio.run(router._route("some-other-model", {}, None))
        self.assertEqual(chosen, "some-other-model")

    def test_unmanaged_model_passes_through_real_hook_with_opaque_metadata(self):
        router = QuotabotRouter()
        router.policy = Policy(models={"frontier": []})
        data = {"model": "some-other-model", "metadata": "client-value"}

        result = asyncio.run(router.async_pre_call_hook(None, None, data, "completion"))

        self.assertIs(result, data)
        self.assertEqual(
            data,
            {"model": "some-other-model", "metadata": "client-value"},
        )

    def test_unmanaged_model_cannot_spoof_reserved_routing_metadata(self):
        router = QuotabotRouter()
        data = {
            "model": "some-other-model",
            "metadata": {
                "client_value": "preserved",
                "quotabot_routed": True,
                "quotabot_spend": "local",
                "quotabot_provider": "claude",
                "quotabot_account": "spoofed@example.com",
                "quotabot_decision_id": "qb-1782000000-0123456789abcdef",
                "quotabot_lease_id": "spoofed-lease-0001",
                "quotabot_original_model": "frontier",
            },
        }

        result = asyncio.run(router.async_pre_call_hook(None, None, data, "completion"))

        self.assertIs(result, data)
        self.assertEqual(data["metadata"], {"client_value": "preserved"})

    def test_unexpected_unmanaged_route_error_retains_fail_soft_passthrough(self):
        router = QuotabotRouter()

        async def broken_route(requested, data, key):
            raise RuntimeError("unexpected unmanaged failure")

        router._route = broken_route  # type: ignore[method-assign]
        data = {"model": "unmanaged"}

        result = asyncio.run(router.async_pre_call_hook(None, None, data, "completion"))

        self.assertIs(result, data)
        self.assertEqual(data, {"model": "unmanaged"})

    def test_scalar_and_list_metadata_fail_closed_for_managed_routes(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [Candidate(deployment="safe-local", local=True)],
            }
        )

        async def availability():
            return []

        router._availability = availability  # type: ignore[method-assign]
        for metadata in ("client-value", ["client-value"]):
            with self.subTest(metadata=metadata):
                data = {"model": "frontier", "metadata": metadata}
                with self.assertRaisesRegex(
                    UnsafeRouteError,
                    "metadata must be an object for a managed route",
                ):
                    asyncio.run(
                        router.async_pre_call_hook(
                            None,
                            None,
                            data,
                            "completion",
                        )
                    )
                self.assertEqual(data["model"], "frontier")
                self.assertIs(data["metadata"], metadata)

    def test_null_metadata_is_normalized_for_a_managed_route(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [Candidate(deployment="safe-local", local=True)],
            }
        )

        async def availability():
            return []

        router._availability = availability  # type: ignore[method-assign]
        data = {"model": "frontier", "metadata": None}

        result = asyncio.run(router.async_pre_call_hook(None, None, data, "completion"))

        self.assertIs(result, data)
        self.assertEqual(data["model"], "safe-local")
        self.assertEqual(data["metadata"]["quotabot_original_model"], "frontier")
        self.assertEqual(data["metadata"]["quotabot_spend"], "local")

    def test_unexpected_managed_route_error_fails_closed(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-subscription",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ]
            }
        )

        async def broken_availability():
            raise RuntimeError("unexpected managed failure")

        router._availability = broken_availability  # type: ignore[method-assign]
        with self.assertRaisesRegex(
            UnsafeRouteError,
            'could not safely route managed model "frontier"',
        ):
            asyncio.run(
                router.async_pre_call_hook(
                    None,
                    None,
                    {"model": "frontier"},
                    "completion",
                )
            )

    def test_agent_redirect_to_missing_logical_model_fails_closed(self):
        router = QuotabotRouter()
        router.policy = Policy(
            agents={"agent-a": AgentRule(model="missing-logical-model")},
        )
        key = type("Key", (), {"key_alias": "agent-a", "user_id": None})()

        with self.assertRaisesRegex(UnsafeRouteError, "no safe"):
            asyncio.run(
                router.async_pre_call_hook(
                    key,
                    None,
                    {"model": "potentially-paid-default"},
                    "completion",
                )
            )

    def test_malformed_candidate_fields_cannot_enable_quota_route(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-subscription",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ],
            }
        )

        malformed = (
            {"available": "false", "effective_headroom_percent": 90},
            {"available": True, "effective_headroom_percent": float("nan")},
            {"available": True, "effective_headroom_percent": True},
            {"available": True, "effective_headroom_percent": 101},
            {
                "available": True,
                "stale": True,
                "effective_headroom_percent": 90,
            },
            {
                "available": True,
                "drift_reason": "rejected evidence",
                "effective_headroom_percent": 90,
            },
        )
        for fields in malformed:
            with self.subTest(fields=fields):

                async def availability(fields=fields):
                    return [{"provider": "claude", **fields}]

                router._availability = availability  # type: ignore[method-assign]
                with self.assertRaisesRegex(UnsafeRouteError, "no safe"):
                    asyncio.run(router._route("frontier", {}, None))

    def test_malformed_suggest_payload_fails_closed_through_real_hook(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-subscription",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ]
            }
        )
        router._fetch_suggest = lambda: []  # type: ignore[method-assign,return-value]

        with self.assertRaisesRegex(UnsafeRouteError, "no safe"):
            asyncio.run(
                router.async_pre_call_hook(
                    None,
                    None,
                    {"model": "frontier"},
                    "completion",
                )
            )

    def test_quota_plan_candidates_require_overages_disabled(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-subscription",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    ),
                    Candidate(deployment="ollama-qwen", local=True),
                ]
            }
        )

        async def availability():
            return {
                "claude": {
                    "provider": "claude",
                    "available": True,
                    "headroom_percent": 99,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", {}, None))
        self.assertEqual(chosen, "claude-subscription")

    def test_quota_plan_without_overage_proof_uses_local_fallback(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-subscription",
                        provider="claude",
                        spend="quota_plan",
                    ),
                    Candidate(deployment="ollama-qwen", local=True),
                ]
            }
        )

        async def availability():
            return {
                "claude": {
                    "provider": "claude",
                    "available": True,
                    "headroom_percent": 99,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", {}, None))
        self.assertEqual(chosen, "ollama-qwen")

    def test_quota_plan_without_overage_proof_fails_closed(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-subscription",
                        provider="claude",
                        spend="quota_plan",
                    )
                ]
            }
        )

        async def availability():
            return {
                "claude": {
                    "provider": "claude",
                    "available": True,
                    "headroom_percent": 99,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        with self.assertRaises(UnsafeRouteError):
            asyncio.run(router._route("frontier", {}, None))

    def test_route_marks_spend_class_for_local_metrics(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "cheap-bulk": [
                    Candidate(deployment="ollama-qwen", local=True),
                ]
            }
        )
        data = {}

        chosen = asyncio.run(router._route("cheap-bulk", data, None))

        self.assertEqual(chosen, "ollama-qwen")
        self.assertEqual(data["metadata"]["quotabot_spend"], "local")

    def test_spend_local_marks_candidate_local(self):
        candidate = Candidate(deployment="local-server", spend="local")

        self.assertTrue(candidate.local)
        self.assertEqual(candidate.spend, "local")

    def test_programmatic_overage_proof_requires_true_boolean(self):
        candidate = Candidate(
            deployment="claude-subscription",
            spend="quota_plan",
            overages_disabled="true",  # type: ignore[arg-type]
        )
        rule = AgentRule(
            pin="claude-subscription",
            pin_spend="quota_plan",
            pin_overages_disabled="true",  # type: ignore[arg-type]
        )

        self.assertFalse(candidate.overages_disabled)
        self.assertFalse(rule.pin_overages_disabled)

    def test_paid_api_candidates_require_explicit_opt_in(self):
        router = QuotabotRouter()
        router.policy = Policy(
            allow_paid_api=True,
            models={
                "frontier": [
                    Candidate(deployment="xai-api", provider="grok", spend="paid_api")
                ]
            },
        )

        async def availability():
            return {
                "grok": {
                    "provider": "grok",
                    "available": True,
                    "headroom_percent": 99,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", {}, None))
        self.assertEqual(chosen, "xai-api")

    def test_managed_model_fails_closed_without_safe_candidate(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(deployment="xai-api", provider="grok", spend="paid_api")
                ]
            }
        )

        async def availability():
            return {
                "grok": {
                    "provider": "grok",
                    "available": True,
                    "headroom_percent": 99,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        with self.assertRaises(UnsafeRouteError):
            asyncio.run(router._route("frontier", {}, None))

    def test_quotabot_unreachable_uses_local_fallback(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-subscription",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    ),
                    Candidate(deployment="ollama-qwen", local=True),
                ]
            }
        )

        async def availability():
            return None

        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(router._route("frontier", {}, None))
        self.assertEqual(chosen, "ollama-qwen")

    def test_agent_model_redirect_uses_trusted_key_alias(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "bulk": [Candidate(deployment="ollama-qwen", local=True)],
                "frontier": [
                    Candidate(
                        deployment="claude-sonnet",
                        provider="claude",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ],
            },
            agents={
                "trusted-agent": AgentRule(model="bulk"),
                "spoofed-agent": AgentRule(model="frontier"),
            },
        )

        async def availability():
            return {
                "claude": {
                    "provider": "claude",
                    "available": True,
                    "headroom_percent": 90,
                }
            }

        router._availability = availability  # type: ignore[method-assign]
        chosen = asyncio.run(
            router._route(
                "frontier",
                {"metadata": {"agent": "spoofed-agent"}},
                _Key(),
            )
        )
        self.assertEqual(chosen, "ollama-qwen")

    def test_policy_accepts_loopback_quotabot_urls_only(self):
        self.assertTrue(_is_loopback_url("http://127.0.0.1:8721"))
        self.assertTrue(_is_loopback_url("http://[::1]:8721"))
        self.assertTrue(_is_loopback_url("http://localhost:8721"))
        self.assertFalse(_is_loopback_url("file:///etc/passwd"))
        self.assertFalse(_is_loopback_url("http://169.254.169.254/latest"))
        self.assertFalse(_is_loopback_url("http://user:secret@localhost:8721"))
        self.assertFalse(_is_loopback_url("http://localhost:8721?profile=work"))
        self.assertFalse(_is_loopback_url("http://localhost:8721/proxy-prefix"))
        self.assertFalse(_is_loopback_url("http://localhost:8721/#fragment"))
        self.assertFalse(_is_loopback_url("http://localhost:99999"))
        self.assertFalse(_is_loopback_url(" http://localhost:8721"))

        policy = Policy(quotabot_url="http://169.254.169.254/latest")
        self.assertEqual(policy.quotabot_url, "http://127.0.0.1:8721")

    def test_loopback_opener_never_inherits_environment_proxies(self):
        proxy_handlers = [
            handler
            for handler in _NO_REDIRECT_OPENER.handlers
            if isinstance(handler, urllib.request.ProxyHandler)
        ]
        self.assertEqual(proxy_handlers, [])

    def test_reserved_account_prefers_exact_candidate_over_wildcard(self):
        wildcard = Candidate(
            deployment="claude-default",
            provider="claude",
            spend="quota_plan",
            overages_disabled=True,
        )
        exact = Candidate(
            deployment="claude-work",
            provider="claude",
            account="work-account",
            spend="quota_plan",
            overages_disabled=True,
        )

        selected = _candidate_for_reserved_target(
            [wildcard, exact],
            "claude",
            "work-account",
        )

        self.assertIs(selected, exact)

    def test_empty_availability_is_cached_not_refetched_every_call(self):
        # A legitimately empty ranked list (e.g. only local runtimes connected)
        # must be cached for the TTL. Freshness is tracked by _cache_at, not the
        # list's truthiness, so this no longer re-fetches on every request.
        router = QuotabotRouter()
        calls = {"n": 0}

        def fake_fetch():
            calls["n"] += 1
            return {"schema": "quotabot.suggest.v1", "ranked": []}

        router._fetch_suggest = fake_fetch  # type: ignore[method-assign]

        async def run_twice():
            first = await router._availability()
            second = await router._availability()
            return first, second

        first, second = asyncio.run(run_twice())
        self.assertEqual(first, [])
        self.assertEqual(second, [])
        self.assertEqual(calls["n"], 1, "empty availability must be cached")

    def test_unavailable_response_cache_expires_and_recovers(self):
        router = QuotabotRouter()
        router.policy = Policy(snapshot_ttl_seconds=30)
        calls = {"n": 0}
        clock = {"now": 100.0}

        def fake_fetch():
            calls["n"] += 1
            if calls["n"] == 1:
                return None
            return {
                "schema": "quotabot.suggest.v1",
                "ranked": [
                    {
                        "provider": "claude",
                        "available": True,
                        "effective_headroom_percent": 75,
                    }
                ],
            }

        router._fetch_suggest = fake_fetch  # type: ignore[method-assign]

        async def exercise_cache():
            first = await router._availability()
            clock["now"] += 4.9
            cached_failure = await router._availability()
            clock["now"] += 0.2
            recovered = await router._availability()
            cached_success = await router._availability()
            return first, cached_failure, recovered, cached_success

        with unittest.mock.patch(
            "quotabot_router.time.monotonic",
            side_effect=lambda: clock["now"],
        ):
            first, cached_failure, recovered, cached_success = asyncio.run(
                exercise_cache()
            )
        self.assertIsNone(first)
        self.assertIsNone(cached_failure)
        self.assertEqual(recovered[0]["provider"], "claude")
        self.assertIs(cached_success, recovered)
        self.assertEqual(calls["n"], 2)

    def test_unknown_suggest_schema_fails_closed(self):
        router = QuotabotRouter()
        router._fetch_suggest = lambda: {  # type: ignore[method-assign]
            "schema": "quotabot.suggest.v999",
            "ranked": [],
        }

        self.assertIsNone(asyncio.run(router._availability()))

    def test_route_propagates_content_blind_decision_id(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "frontier": [
                    Candidate(
                        deployment="codex-high",
                        provider="codex",
                        spend="quota_plan",
                        overages_disabled=True,
                    )
                ]
            }
        )
        router._fetch_suggest = lambda: {  # type: ignore[method-assign]
            "schema": "quotabot.suggest.v1",
            "ranked": [
                {
                    "provider": "codex",
                    "available": True,
                    "effective_headroom_percent": 80,
                }
            ],
            "receipt": {
                "schema": "quotabot.receipt.v1",
                "decision_id": "qb-1782000000-0123456789abcdef",
            },
        }

        data = {}
        chosen = asyncio.run(router._route("frontier", data, None))

        self.assertEqual(chosen, "codex-high")
        self.assertEqual(
            data["metadata"]["quotabot_decision_id"],
            "qb-1782000000-0123456789abcdef",
        )

    def test_fetch_suggest_does_not_follow_redirects(self):
        requests = {"suggest": 0, "redirected": 0}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/suggest":
                    requests["suggest"] += 1
                    self.send_response(302)
                    self.send_header("Location", "/redirected")
                    self.end_headers()
                    return
                if self.path == "/redirected":
                    requests["redirected"] += 1
                    body = json.dumps(
                        {
                            "schema": "quotabot.suggest.v1",
                            "ranked": [
                                {
                                    "provider": "claude",
                                    "available": True,
                                    "effective_headroom_percent": 75,
                                }
                            ],
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_error(404)

            def log_message(self, format, *args):
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        router = QuotabotRouter()
        router.policy = Policy(quotabot_url=f"http://127.0.0.1:{server.server_port}")
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always", ResourceWarning)
            self.assertIsNone(router._fetch_suggest())
        self.assertEqual(requests["suggest"], 1)
        self.assertEqual(
            requests["redirected"],
            0,
            "redirect target must never receive a request",
        )
        self.assertFalse(
            any(item.category is ResourceWarning for item in caught),
            "redirect response must be closed explicitly",
        )

    def test_metrics_path_is_constrained_to_quotabot_home(self):
        inside = Policy(metrics_path="~/.quotabot/routing.jsonl")
        inside_path = Path(inside.metrics_path)
        self.assertEqual(inside_path.name, "routing.jsonl")
        self.assertEqual(inside_path.parent.name, ".quotabot")

        relative = Policy(metrics_path="routing.jsonl")
        relative_path = Path(relative.metrics_path)
        self.assertEqual(relative_path.name, "routing.jsonl")
        self.assertEqual(relative_path.parent.name, ".quotabot")

        with tempfile.TemporaryDirectory() as tmp:
            outside = Policy(metrics_path=str(Path(tmp) / "routing.jsonl"))
            self.assertIsNone(outside.metrics_path)

    def test_policy_loads_spend_and_paid_api_controls(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.yaml"
            path.write_text(
                """
allow_paid_api: true
block_unsafe_passthrough: false
lease_seconds: 300
lease_weight_percent: 22.5
models:
  frontier:
    candidates:
      - deployment: xai-api
        provider: grok
        spend: paid_api
      - deployment: claude-subscription
        provider: claude
        account: work@example.com
        spend: quota_plan
        overages: disabled
      - deployment: misconfigured-subscription
        provider: claude
        spend: quota_plan
        overages_disabled: false
        overages: disabled
agents:
  architect:
    pin: claude-subscription
    pin_spend: quota_plan
    pin_overages_disabled: true
""",
                encoding="utf-8",
            )

            policy = Policy.load(path)

        self.assertTrue(policy.allow_paid_api)
        self.assertFalse(policy.block_unsafe_passthrough)
        self.assertEqual(policy.lease_seconds, 300)
        self.assertEqual(policy.lease_weight_percent, 22.5)
        self.assertEqual(policy.models["frontier"][0].spend, "paid_api")
        self.assertEqual(policy.models["frontier"][1].spend, "quota_plan")
        self.assertEqual(policy.models["frontier"][1].account, "work@example.com")
        self.assertTrue(policy.models["frontier"][1].overages_disabled)
        self.assertFalse(policy.models["frontier"][2].overages_disabled)
        self.assertEqual(policy.agents["architect"].pin_spend, "quota_plan")
        self.assertTrue(policy.agents["architect"].pin_overages_disabled)

    def test_policy_string_booleans_do_not_enable_paid_api(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.yaml"
            path.write_text(
                """
allow_paid_api: "false"
block_unsafe_passthrough: "true"
models:
  frontier:
    candidates:
      - deployment: ollama-qwen
        local: "true"
""",
                encoding="utf-8",
            )

            policy = Policy.load(path)

        self.assertFalse(policy.allow_paid_api)
        self.assertTrue(policy.block_unsafe_passthrough)
        self.assertTrue(policy.models["frontier"][0].local)
        self.assertEqual(policy.models["frontier"][0].spend, "local")

    def test_local_mutation_token_file_is_loaded_and_validated(self):
        with tempfile.TemporaryDirectory() as tmp:
            token_file = Path(tmp) / "quotabot" / "http" / "mutation_token"
            token_file.parent.mkdir(parents=True)
            token_file.write_text(
                "file-backed-local-mutation-token-0123456789\n",
                encoding="utf-8",
            )
            environment = {
                "LOCALAPPDATA": tmp,
                "QUOTABOT_HTTP_TOKEN": "",
                "QUOTABOT_HTTP_TOKEN_FILE": "",
            }
            with unittest.mock.patch.dict(os.environ, environment):
                self.assertEqual(
                    _load_local_http_token(),
                    "file-backed-local-mutation-token-0123456789",
                )
                token_file.write_text("invalid token", encoding="utf-8")
                self.assertIsNone(_load_local_http_token())

    def test_success_metrics_include_spend_class(self):
        class Usage:
            prompt_tokens = 10
            completion_tokens = 2

        class Response:
            usage = Usage()

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "metrics.jsonl"
            router = QuotabotRouter()
            router.policy = Policy()
            router.policy.metrics_path = str(path)
            open_modes = []
            original_open = os.open

            def capture_open(*args, **kwargs):
                if Path(args[0]) == path:
                    open_modes.append(args[2] if len(args) >= 3 else kwargs.get("mode"))
                return original_open(*args, **kwargs)

            with unittest.mock.patch("quotabot_router.os.open", capture_open):
                asyncio.run(
                    router.async_log_success_event(
                        {
                            "model": "ollama-qwen",
                            "response_cost": 0,
                            "litellm_params": {
                                "metadata": {
                                    "quotabot_routed": True,
                                    "quotabot_original_model": "cheap-bulk",
                                    "quotabot_spend": "local",
                                    "quotabot_decision_id": "qb-1782000000-0123456789abcdef",
                                }
                            },
                        },
                        Response(),
                        None,
                        None,
                    )
                )

            record = json.loads(path.read_text(encoding="utf-8").strip())
            if os.name != "nt":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)

        self.assertEqual(record["requested_model"], "cheap-bulk")
        self.assertEqual(record["served_model"], "ollama-qwen")
        self.assertEqual(record["spend"], "local")
        self.assertEqual(
            record["decision_id"],
            "qb-1782000000-0123456789abcdef",
        )
        self.assertEqual(record["prompt_tokens"], 10)
        self.assertEqual(open_modes, [0o600])

    def test_failure_metrics_include_pipe_health_without_messages(self):
        class Response:
            status_code = 429
            headers = {"Retry-After": "120"}

        class RateLimitError(Exception):
            status_code = 429
            response = Response()

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "metrics.jsonl"
            router = QuotabotRouter()
            router.policy = Policy()
            router.policy.metrics_path = str(path)
            asyncio.run(
                router.async_log_failure_event(
                    {
                        "model": "claude-sonnet",
                        "exception": RateLimitError("do not log this message"),
                        "response_cost": 0.03,
                        "usage": {
                            "prompt_tokens": 12,
                            "completion_tokens": 4,
                        },
                        "litellm_params": {
                            "metadata": {
                                "quotabot_routed": True,
                                "quotabot_original_model": "frontier",
                                "quotabot_spend": "quota_plan",
                                "quotabot_provider": "claude",
                                "quotabot_account": "work@example.com",
                            }
                        },
                    },
                    None,
                    100.0,
                    101.25,
                )
            )

            record = json.loads(path.read_text(encoding="utf-8").strip())

        self.assertEqual(record["event"], "failure")
        self.assertEqual(record["provider"], "claude")
        self.assertEqual(record["account"], "work@example.com")
        self.assertEqual(record["requested_model"], "frontier")
        self.assertEqual(record["served_model"], "claude-sonnet")
        self.assertEqual(record["spend"], "quota_plan")
        self.assertEqual(record["http_status"], 429)
        self.assertEqual(record["retry_after_seconds"], 120)
        self.assertEqual(record["latency_ms"], 1250)
        self.assertEqual(record["error_type"], "RateLimitError")
        self.assertEqual(record["prompt_tokens"], 12)
        self.assertEqual(record["completion_tokens"], 4)
        self.assertEqual(record["cost"], 0.03)
        self.assertNotIn("do not log", json.dumps(record))


class LeaseHttpTests(unittest.TestCase):
    def test_malformed_reserved_candidate_is_released_and_rejected(self):
        token = "local-test-mutation-token-0123456789"
        releases = []
        router = QuotabotRouter()
        router.policy = Policy()

        def mutation(path, payload, supplied_token):
            self.assertEqual(supplied_token, token)
            if path == "/leases/release":
                releases.append(payload["lease_id"])
                return {"schema": "quotabot.release.v1", "released": True}
            return {
                "schema": "quotabot.reserve.v1",
                "reserved": True,
                "reused": False,
                "lease": {
                    "id": "malformed-test-lease-0001",
                    "provider": "claude",
                    "account": "work-account",
                    "created_at": 100,
                    "expires_at": 220,
                    "weight_percent": 15,
                    "client": "litellm",
                    "idempotency_key": payload["idempotency_key"],
                },
                "selected": {
                    "provider": "claude",
                    "account": "work-account",
                    "available": True,
                    "stale": "false",
                    "effective_headroom_percent": 80,
                },
                "decision_id": "qb-1782000000-0123456789abcdef",
            }

        router._post_mutation = mutation  # type: ignore[method-assign]
        candidate = Candidate(
            deployment="claude-work",
            provider="claude",
            account="work-account",
            spend="quota_plan",
            overages_disabled=True,
        )
        with unittest.mock.patch.dict(os.environ, {"QUOTABOT_HTTP_TOKEN": token}):
            selected = asyncio.run(router._reserve_remote([candidate], [], 15, None))

        self.assertIsNone(selected)
        self.assertEqual(releases, ["malformed-test-lease-0001"])

    def test_parallel_routes_reserve_distinct_providers_and_release(self):
        token = "local-test-mutation-token-0123456789"
        state = {
            "authorizations": [],
            "reservations": [],
            "releases": [],
        }
        state_lock = Lock()

        class Handler(BaseHTTPRequestHandler):
            def _write_json(self, status, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path != "/suggest":
                    self._write_json(404, {"error": "not found"})
                    return
                self._write_json(
                    200,
                    {
                        "schema": "quotabot.suggest.v1",
                        "ranked": [
                            {
                                "provider": "claude",
                                "account": "claude-account",
                                "available": True,
                                "effective_headroom_percent": 80,
                            },
                            {
                                "provider": "codex",
                                "account": "codex-account",
                                "available": True,
                                "effective_headroom_percent": 70,
                            },
                        ],
                        "receipt": {
                            "schema": "quotabot.receipt.v1",
                            "decision_id": "qb-1782000000-0123456789abcdef",
                        },
                    },
                )

            def do_POST(self):
                authorization = self.headers.get("Authorization")
                with state_lock:
                    state["authorizations"].append(authorization)
                if authorization != f"Bearer {token}":
                    self._write_json(401, {"error": "unauthorized"})
                    return
                try:
                    length = int(self.headers.get("Content-Length") or "0")
                    payload = json.loads(self.rfile.read(length).decode("utf-8"))
                except (UnicodeError, ValueError):
                    self._write_json(400, {"error": "invalid body"})
                    return
                if self.path == "/leases/reserve":
                    with state_lock:
                        reservation_number = len(state["reservations"]) + 1
                        state["reservations"].append(payload)
                    if reservation_number == 1:
                        provider, account = "claude", "claude-account"
                    else:
                        provider, account = "codex", "codex-account"
                    lease_id = f"lease-test-{reservation_number:04d}"
                    self._write_json(
                        200,
                        {
                            "schema": "quotabot.reserve.v1",
                            "reserved": True,
                            "reused": False,
                            "lease": {
                                "id": lease_id,
                                "provider": provider,
                                "account": account,
                                "created_at": 1782000000,
                                "expires_at": 1782000120,
                                "weight_percent": payload["weight_percent"],
                                "client": payload["client"],
                                "idempotency_key": payload["idempotency_key"],
                            },
                            "selected": {
                                "provider": provider,
                                "account": account,
                                "available": True,
                                "effective_headroom_percent": 65,
                            },
                            "decision_id": (
                                "qb-1782000000-0000000000000001"
                                if reservation_number == 1
                                else "qb-1782000000-0000000000000002"
                            ),
                        },
                    )
                    return
                if self.path == "/leases/release":
                    with state_lock:
                        state["releases"].append(payload.get("lease_id"))
                    self._write_json(
                        200,
                        {
                            "schema": "quotabot.release.v1",
                            "released": True,
                        },
                    )
                    return
                self._write_json(404, {"error": "not found"})

            def log_message(self, format, *args):
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        router = QuotabotRouter()
        router.policy = Policy(
            quotabot_url=f"http://127.0.0.1:{server.server_port}",
            lease_weight_percent=50,
            models={
                "frontier": [
                    Candidate(
                        deployment="claude-sonnet",
                        provider="claude",
                        account="claude-account",
                        spend="quota_plan",
                        overages_disabled=True,
                    ),
                    Candidate(
                        deployment="codex-gpt",
                        provider="codex",
                        account="codex-account",
                        spend="quota_plan",
                        overages_disabled=True,
                    ),
                ]
            },
        )

        async def exercise():
            first = {"model": "frontier"}
            second = {"model": "frontier"}
            await asyncio.gather(
                router.async_pre_call_hook(None, None, first, "completion"),
                router.async_pre_call_hook(None, None, second, "completion"),
            )
            await asyncio.gather(
                router.async_log_success_event(
                    {
                        "model": first["model"],
                        "litellm_params": {"metadata": first["metadata"]},
                    },
                    None,
                    None,
                    None,
                ),
                router.async_log_failure_event(
                    {
                        "model": second["model"],
                        "litellm_params": {"metadata": second["metadata"]},
                    },
                    None,
                    None,
                    None,
                ),
            )
            return first, second

        with unittest.mock.patch.dict(
            os.environ,
            {"QUOTABOT_HTTP_TOKEN": token},
        ):
            first, second = asyncio.run(exercise())

        self.assertEqual(
            {first["model"], second["model"]}, {"claude-sonnet", "codex-gpt"}
        )
        lease_ids = {
            first["metadata"]["quotabot_lease_id"],
            second["metadata"]["quotabot_lease_id"],
        }
        self.assertEqual(lease_ids, {"lease-test-0001", "lease-test-0002"})
        self.assertEqual(len(state["reservations"]), 2)
        for reservation in state["reservations"]:
            self.assertEqual(
                reservation["targets"],
                [
                    {"provider": "claude", "account": "claude-account"},
                    {"provider": "codex", "account": "codex-account"},
                ],
            )
            self.assertEqual(reservation["weight_percent"], 50.0)
        self.assertEqual(set(state["releases"]), lease_ids)
        self.assertEqual(
            state["authorizations"],
            [f"Bearer {token}"] * 4,
        )


if __name__ == "__main__":
    unittest.main()
