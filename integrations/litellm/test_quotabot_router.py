import asyncio
import base64
import functools
import ipaddress
import json
import os
import socketserver
import ssl
import tempfile
import time
import unittest
import unittest.mock
import urllib.parse
import warnings
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Lock, Thread

from local_metadata import (
    _OwnedHTTPSConnection,
    local_metadata_request,
    local_server_proof as _local_server_proof,
    run_metadata_operation,
)

with unittest.mock.patch.dict(os.environ, {"LITELLM_LOCAL_MODEL_COST_MAP": "True"}):
    from quotabot_router import (
        AgentRule,
        Candidate,
        Policy,
        QuotabotRouter,
        UnsafeRouteError,
        _LeaseChoice,
        _best_ranked_candidate,
        _candidate_for_reserved_target,
        _is_loopback_url,
        _load_local_http_token,
        _metric_info_for_candidate,
        _reservation_candidates,
    )


def _server_endpoint(handler: BaseHTTPRequestHandler) -> str:
    local = handler.connection.getsockname()
    address = ipaddress.ip_address(str(local[0]).split("%", 1)[0])
    encoded = base64.urlsafe_b64encode(address.packed).rstrip(b"=").decode("ascii")
    return f"{encoded}:{int(local[1])}"


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

    def test_ambiguous_provider_accounts_require_explicit_deployment_mapping(self):
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

        self.reserve_patch.stop()
        data = {}
        router._availability = availability  # type: ignore[method-assign]
        with unittest.mock.patch.object(router, "_post_mutation") as mutation:
            with self.assertRaises(UnsafeRouteError):
                asyncio.run(router._route("frontier", data, None))
        mutation.assert_not_called()
        self.assertNotIn("metadata", data)

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

    def test_prebound_impostor_never_receives_mutation_bearer(self):
        token = "local-test-mutation-token-0123456789"
        requests_seen = []

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                requests_seen.append((self.path, self.headers.get("Authorization")))
                query = urllib.parse.urlsplit(self.path)
                nonce = urllib.parse.parse_qs(query.query).get("nonce", [""])[0]
                body = json.dumps(
                    {
                        "schema": "quotabot.local-server-proof.v1",
                        "nonce": nonce,
                        "proof": "0" * 64,
                    }
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        router = QuotabotRouter()
        router.policy = Policy(quotabot_url=f"http://127.0.0.1:{server.server_port}")
        with unittest.mock.patch.dict(os.environ, {"QUOTABOT_HTTP_TOKEN": token}):
            self.assertIsNone(router._fetch_suggest())

        self.assertEqual(len(requests_seen), 1)
        self.assertTrue(requests_seen[0][0].startswith("/auth/prove?nonce="))
        self.assertIsNone(requests_seen[0][1])

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

    def test_policy_rejects_out_of_range_lease_fields(self):
        with self.assertRaisesRegex(ValueError, "lease_seconds"):
            Policy(lease_seconds=14)
        with self.assertRaisesRegex(ValueError, "lease_seconds"):
            Policy(lease_seconds=3601)
        with self.assertRaisesRegex(ValueError, "lease_weight_percent"):
            Policy(lease_weight_percent=0.5)
        with self.assertRaisesRegex(ValueError, "lease_weight_percent"):
            Policy(lease_weight_percent=99)
        for invalid in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(lease_weight_percent=invalid):
                with self.assertRaisesRegex(ValueError, "lease_weight_percent"):
                    Policy(lease_weight_percent=invalid)

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.yaml"
            path.write_text("lease_seconds: 99\n", encoding="utf-8")
            policy = Policy.load(path)
            self.assertEqual(policy.lease_seconds, 99)

            path.write_text("lease_seconds: 14\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "lease_seconds"):
                Policy.load(path)

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

    def test_callback_metrics_fail_soft_with_bounded_warning_and_release(self):
        route_metadata = {
            "quotabot_routed": True,
            "quotabot_lease_id": "test-lease-0001",
        }
        kwargs = {
            "model": "claude-sonnet",
            "litellm_params": {"metadata": route_metadata},
        }

        for callback_name in (
            "async_log_success_event",
            "async_log_failure_event",
        ):
            with self.subTest(callback=callback_name):
                router = QuotabotRouter()
                router.policy = Policy()
                router.policy.metrics_path = "unused-routing-metrics.jsonl"
                release = unittest.mock.AsyncMock()
                with (
                    unittest.mock.patch.object(
                        router,
                        "_append_metric",
                        side_effect=RuntimeError("private metrics path"),
                    ),
                    unittest.mock.patch.object(
                        router,
                        "_release_route_lease",
                        release,
                    ),
                    self.assertLogs("quotabot_router", level="WARNING") as captured,
                ):
                    asyncio.run(
                        getattr(router, callback_name)(kwargs, None, None, None)
                    )

                release.assert_awaited_once_with(route_metadata)
                self.assertEqual(
                    captured.output,
                    [
                        "WARNING:quotabot_router:quotabot metrics write failed; "
                        "routing callback continued"
                    ],
                )
                self.assertNotIn("private metrics path", captured.output[0])

    def test_callback_release_failure_is_bounded_and_fail_soft(self):
        route_metadata = {
            "quotabot_routed": True,
            "quotabot_lease_id": "test-lease-0002",
        }
        kwargs = {
            "model": "claude-sonnet",
            "litellm_params": {"metadata": route_metadata},
        }

        for callback_name in (
            "async_log_success_event",
            "async_log_failure_event",
        ):
            with self.subTest(callback=callback_name):
                router = QuotabotRouter()
                router.policy = Policy()
                release = unittest.mock.AsyncMock(
                    side_effect=RuntimeError("private lease detail")
                )
                with (
                    unittest.mock.patch.object(
                        router,
                        "_release_route_lease",
                        release,
                    ),
                    self.assertLogs("quotabot_router", level="WARNING") as captured,
                ):
                    asyncio.run(
                        getattr(router, callback_name)(kwargs, None, None, None)
                    )

                release.assert_awaited_once_with(route_metadata)
                self.assertEqual(
                    captured.output,
                    [
                        "WARNING:quotabot_router:quotabot lease release failed; "
                        "lease will expire by TTL"
                    ],
                )
                self.assertNotIn("private lease detail", captured.output[0])


class LeaseHttpTests(unittest.TestCase):
    def test_explicit_blank_account_cannot_become_a_wildcard(self):
        for account in ("", " ", "\t"):
            with self.subTest(account=account):
                with self.assertRaisesRegex(ValueError, "nonempty account label"):
                    Candidate("claude-work", provider="claude", account=account)

    def test_implicit_deployment_requires_one_known_account(self):
        candidate = Candidate(
            deployment="claude-default",
            provider="claude",
            spend="quota_plan",
            overages_disabled=True,
        )
        for ranked in (
            [],
            [{"provider": "claude"}],
            [
                {"provider": "claude", "account": "account-a"},
                {"provider": "claude", "account": "account-b"},
            ],
            [
                {"provider": "claude", "account": "account-a"},
                {"provider": "claude"},
            ],
        ):
            with self.subTest(ranked=ranked):
                router = QuotabotRouter()
                with (
                    unittest.mock.patch(
                        "quotabot_router._load_local_http_token"
                    ) as token,
                    unittest.mock.patch.object(router, "_post_mutation") as mutation,
                ):
                    selected = asyncio.run(
                        router._reserve_remote([candidate], ranked, 15, None)
                    )
                self.assertIsNone(selected)
                token.assert_not_called()
                mutation.assert_not_called()

    def test_explicit_mapping_wins_over_single_account_convenience(self):
        wildcard = Candidate("claude-default", provider="claude")
        exact = Candidate("claude-work", provider="claude", account="account-a")
        bound = _reservation_candidates(
            [wildcard, exact],
            [{"provider": "claude", "account": "account-a"}],
        )
        self.assertIs(
            _candidate_for_reserved_target(bound, "claude", "account-a"), exact
        )
        self.assertIsNone(
            _candidate_for_reserved_target([wildcard], "claude", "account-b")
        )

    def test_implicit_target_cannot_retarget_a_changed_account(self):
        token = "local-test-mutation-token-0123456789"
        candidate = Candidate(
            deployment="claude-default",
            provider="claude",
            spend="quota_plan",
            overages_disabled=True,
        )
        for returned_account in ("account-a", "account-b", None):
            with self.subTest(returned_account=returned_account):
                router = QuotabotRouter()
                releases = []

                def mutation(path, payload, supplied_token):
                    self.assertEqual(supplied_token, token)
                    if path == "/leases/release":
                        releases.append(payload["lease_id"])
                        return {"schema": "quotabot.release.v1", "released": True}
                    self.assertEqual(
                        payload["targets"],
                        [{"provider": "claude", "account": "account-a"}],
                    )
                    return {
                        "schema": "quotabot.reserve.v1",
                        "reserved": True,
                        "reused": False,
                        "lease": {
                            "id": "account-test-lease-0001",
                            "provider": "claude",
                            "account": returned_account,
                            "created_at": 100,
                            "expires_at": 220,
                            "weight_percent": 15,
                            "client": "litellm",
                            "idempotency_key": payload["idempotency_key"],
                        },
                        "selected": {
                            "provider": "claude",
                            "account": returned_account,
                            "available": True,
                            "effective_headroom_percent": 80,
                        },
                        "decision_id": "qb-1782000000-0123456789abcdef",
                    }

                with (
                    unittest.mock.patch.dict(
                        os.environ, {"QUOTABOT_HTTP_TOKEN": token}
                    ),
                    unittest.mock.patch.object(router, "_post_mutation", mutation),
                ):
                    selected = asyncio.run(
                        router._reserve_remote(
                            [candidate],
                            [{"provider": "claude", "account": "account-a"}],
                            15,
                            None,
                        )
                    )
                if returned_account == "account-a":
                    self.assertIsNotNone(selected)
                    self.assertEqual(selected.candidate.deployment, "claude-default")
                    self.assertEqual(selected.candidate.account, "account-a")
                    self.assertEqual(releases, [])
                else:
                    self.assertIsNone(selected)
                    self.assertEqual(releases, ["account-test-lease-0001"])

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
            "proof_authorizations": [],
            "read_authorizations": [],
            "reservations": [],
            "releases": [],
        }
        state_lock = Lock()

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _write_json(self, status, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path == "/auth/prove":
                    nonce = urllib.parse.parse_qs(parsed.query).get("nonce", [""])[0]
                    with state_lock:
                        state["proof_authorizations"].append(
                            self.headers.get("Authorization")
                        )
                    self._write_json(
                        200,
                        {
                            "schema": "quotabot.local-server-proof.v1",
                            "nonce": nonce,
                            "proof": _local_server_proof(
                                token,
                                nonce,
                                _server_endpoint(self),
                            ),
                        },
                    )
                    return
                if self.path != "/suggest":
                    self._write_json(404, {"error": "not found"})
                    return
                with state_lock:
                    state["read_authorizations"].append(
                        self.headers.get("Authorization")
                    )
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
        self.assertEqual(state["read_authorizations"], [f"Bearer {token}"])
        self.assertEqual(state["proof_authorizations"], [None] * 5)


class LocalMetadataTests(unittest.TestCase):
    token = "synthetic-transport-token-0123456789"

    def _start_server(self, phase):
        state = {"requests": [], "closed": Event(), "started": Event()}
        token = self.token

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def handle(self):
                try:
                    super().handle()
                except ConnectionError:
                    state["closed"].set()

            def finish(self):
                try:
                    super().finish()
                finally:
                    state["closed"].set()

            def log_message(self, format, *args):
                return

            def _write(self, raw):
                try:
                    self.wfile.write(raw)
                    self.wfile.flush()
                    return True
                except ConnectionError:
                    state["closed"].set()
                    return False

            def _observe_close(self):
                self.connection.settimeout(1)
                try:
                    if not self.connection.recv(1):
                        state["closed"].set()
                except ConnectionError:
                    state["closed"].set()
                except TimeoutError:
                    pass

            def _drip(self, raw):
                state["started"].set()
                for byte in raw:
                    if not self._write(bytes((byte,))):
                        break
                    time.sleep(0.01)
                self._observe_close()

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                proof = parsed.path == "/auth/prove"
                state["requests"].append(
                    (parsed.path, self.headers.get("Authorization"))
                )
                if proof:
                    nonce = urllib.parse.parse_qs(parsed.query)["nonce"][0]
                    raw = json.dumps(
                        {
                            "schema": "quotabot.local-server-proof.v1",
                            "nonce": nonce,
                            "proof": _local_server_proof(
                                token, nonce, _server_endpoint(self)
                            )
                            if phase != "non_ascii_proof"
                            else "\u00e9" * 64,
                        }
                    ).encode()
                else:
                    raw = b'{"schema":"quotabot.suggest.v1","ranked":[]}'
                target = "proof" if proof else "metadata"
                if phase == f"recursive_{target}":
                    raw = b"[" * 1500 + b"0" + b"]" * 1500
                if phase == f"{target}_headers":
                    self._drip(b"HTTP/1.1 200 OK\r\nX-Drip: " + b"x" * 500)
                    return
                if phase == "metadata_chunked" and not proof:
                    self.send_response(200)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    self._drip(b"1\r\n" + b"0" * 500)
                    return
                if phase == f"{target}_body":
                    raw += b" " * 500
                if phase == "oversize_proof" and proof:
                    raw += b" " * 4096
                self.send_response(200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                if phase == f"{target}_body":
                    self._drip(raw)
                    return
                if phase == "combined_budget":
                    time.sleep(0.18)
                self._write(raw)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(
            target=lambda: server.serve_forever(poll_interval=0.01), daemon=True
        )
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}", state

    def test_loopback_transport_bypasses_environment_proxies(self):
        url, state = self._start_server("normal")
        with unittest.mock.patch.dict(
            os.environ,
            {
                "HTTP_PROXY": "http://127.0.0.1:1",
                "HTTPS_PROXY": "http://127.0.0.1:1",
                "http_proxy": "http://127.0.0.1:1",
                "https_proxy": "http://127.0.0.1:1",
                "NO_PROXY": "",
                "no_proxy": "",
            },
        ):
            raw = local_metadata_request(url, "/suggest", None, maximum=4096)
        self.assertEqual(json.loads(raw)["ranked"], [])
        self.assertEqual(state["requests"], [("/suggest", None)])

    def test_authenticated_transport_preserves_same_peer_proof(self):
        url, state = self._start_server("normal")
        raw = local_metadata_request(url, "/suggest", self.token, maximum=4096)
        self.assertEqual(json.loads(raw)["ranked"], [])
        self.assertEqual(
            state["requests"],
            [("/auth/prove", None), ("/suggest", f"Bearer {self.token}")],
        )

    def test_dripping_headers_and_bodies_have_one_deadline_and_close_socket(self):
        for phase in (
            "proof_headers",
            "proof_body",
            "metadata_headers",
            "metadata_body",
            "metadata_chunked",
        ):
            with self.subTest(phase=phase):
                url, state = self._start_server(phase)
                started = time.monotonic()
                raw = local_metadata_request(
                    url, "/suggest", self.token, maximum=4096, timeout=0.3
                )
                self.assertIsNone(raw)
                self.assertLess(time.monotonic() - started, 1.5)
                self.assertTrue(state["started"].is_set())
                self.assertTrue(state["closed"].wait(1.5), "owned socket must close")
                if phase.startswith("proof_"):
                    self.assertEqual(state["requests"], [("/auth/prove", None)])

    def test_proof_and_metadata_share_the_total_budget(self):
        url, state = self._start_server("combined_budget")
        raw = local_metadata_request(
            url, "/suggest", self.token, maximum=4096, timeout=0.3
        )
        self.assertIsNone(raw, "two individually short phases must share one deadline")
        self.assertEqual(len(state["requests"]), 2)

    def test_oversize_proof_never_sends_bearer(self):
        url, state = self._start_server("oversize_proof")
        self.assertIsNone(
            local_metadata_request(url, "/suggest", self.token, maximum=4096)
        )
        self.assertEqual(state["requests"], [("/auth/prove", None)])

    def test_malformed_proof_fails_soft_without_sending_bearer(self):
        for phase in ("non_ascii_proof", "recursive_proof"):
            with self.subTest(phase=phase):
                url, state = self._start_server(phase)
                self.assertIsNone(
                    local_metadata_request(url, "/suggest", self.token, maximum=4096)
                )
                self.assertEqual(state["requests"], [("/auth/prove", None)])

    def _router_for_dripping_sidecar(self, url, *, local):
        router = QuotabotRouter()
        candidates = [
            Candidate(
                deployment="claude-fixed",
                provider="claude",
                account="synthetic-account",
                spend="quota_plan",
                overages_disabled=True,
            )
        ]
        if local:
            candidates.append(Candidate(deployment="ollama-local", local=True))
        router.policy = Policy(quotabot_url=url, models={"frontier": candidates})
        return router

    def test_concurrent_routes_reach_local_fallback_and_negative_cache(self):
        url, state = self._start_server("metadata_body")
        router = self._router_for_dripping_sidecar(url, local=True)

        async def route_twice():
            requests = [{"model": "frontier"}, {"model": "frontier"}]
            await asyncio.gather(
                *(
                    router.async_pre_call_hook(None, None, data, "completion")
                    for data in requests
                )
            )
            return requests

        with (
            unittest.mock.patch(
                "quotabot_router._load_local_http_token", return_value=None
            ),
            unittest.mock.patch(
                "quotabot_router._local_metadata_request",
                functools.partial(local_metadata_request, timeout=0.3),
            ),
        ):
            started = time.monotonic()
            requests = asyncio.run(route_twice())
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual([data["model"] for data in requests], ["ollama-local"] * 2)
        self.assertEqual(state["requests"], [("/suggest", None)])
        self.assertTrue(state["closed"].wait(1.5))

    def test_timeout_without_local_route_fails_closed_before_reservation(self):
        url, state = self._start_server("metadata_body")
        router = self._router_for_dripping_sidecar(url, local=False)
        with (
            unittest.mock.patch(
                "quotabot_router._load_local_http_token", return_value=None
            ),
            unittest.mock.patch(
                "quotabot_router._local_metadata_request",
                functools.partial(local_metadata_request, timeout=0.3),
            ),
            unittest.mock.patch.object(router, "_post_mutation") as mutate,
        ):
            with self.assertRaises(UnsafeRouteError):
                asyncio.run(
                    router.async_pre_call_hook(
                        None, None, {"model": "frontier"}, "completion"
                    )
                )
        mutate.assert_not_called()
        self.assertTrue(state["closed"].wait(1.5))

    def test_recursive_metadata_reaches_configured_local_fallback(self):
        url, state = self._start_server("recursive_metadata")
        router = self._router_for_dripping_sidecar(url, local=True)
        with unittest.mock.patch(
            "quotabot_router._load_local_http_token", return_value=None
        ):
            data = asyncio.run(
                router.async_pre_call_hook(
                    None, None, {"model": "frontier"}, "completion"
                )
            )
        self.assertEqual(data["model"], "ollama-local")
        self.assertEqual(state["requests"], [("/suggest", None)])

    def test_cancelled_route_worker_closes_by_the_same_deadline(self):
        url, state = self._start_server("metadata_body")
        router = self._router_for_dripping_sidecar(url, local=True)

        async def cancel_route():
            task = asyncio.create_task(
                router.async_pre_call_hook(
                    None, None, {"model": "frontier"}, "completion"
                )
            )
            self.assertTrue(await asyncio.to_thread(state["started"].wait, 1.5))
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            self.assertTrue(await asyncio.to_thread(state["closed"].wait, 1.5))

        with (
            unittest.mock.patch(
                "quotabot_router._load_local_http_token", return_value=None
            ),
            unittest.mock.patch(
                "quotabot_router._local_metadata_request",
                functools.partial(local_metadata_request, timeout=0.3),
            ),
        ):
            asyncio.run(cancel_route())

    def test_stalled_tls_handshake_is_owned_and_bounded(self):
        closed = Event()

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(1.5)
                try:
                    while self.request.recv(4096):
                        pass
                    closed.set()
                except ConnectionError:
                    closed.set()

        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        thread = Thread(
            target=lambda: server.serve_forever(poll_interval=0.01), daemon=True
        )
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        started = time.monotonic()
        self.assertIsNone(
            local_metadata_request(
                f"https://127.0.0.1:{server.server_address[1]}",
                "/suggest",
                self.token,
                maximum=4096,
                timeout=0.3,
            )
        )
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertTrue(closed.wait(1.5))
        connection = _OwnedHTTPSConnection("localhost", 443, timeout=0.3)
        self.assertTrue(connection._tls_context.check_hostname)
        self.assertEqual(connection._tls_context.verify_mode, ssl.CERT_REQUIRED)

    def test_async_caller_is_bounded_before_socket_creation(self):
        url, state = self._start_server("normal")
        import http.client

        connect = http.client.HTTPConnection.connect

        def delayed_connect(connection):
            time.sleep(0.35)
            connect(connection)

        async def request():
            started = time.monotonic()
            result = await run_metadata_operation(
                local_metadata_request,
                url,
                "/suggest",
                self.token,
                maximum=4096,
                timeout=0.1,
            )
            return result, time.monotonic() - started

        with (
            unittest.mock.patch("http.client.HTTPConnection.connect", delayed_connect),
            unittest.mock.patch("local_metadata.LOCAL_METADATA_TIMEOUT_SECONDS", 0.1),
        ):
            result, elapsed = asyncio.run(request())
        self.assertIsNone(result)
        self.assertLess(elapsed, 0.3)
        self.assertTrue(state["closed"].wait(1.5))
        self.assertEqual(
            state["requests"], [], "an expired late connection must send nothing"
        )

    def test_late_tcp_connection_never_starts_tls_handshake(self):
        import http.client

        closed = Event()
        wire = []

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(1.5)
                try:
                    while chunk := self.request.recv(4096):
                        wire.append(chunk)
                    closed.set()
                except ConnectionError:
                    closed.set()

        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        thread = Thread(
            target=lambda: server.serve_forever(poll_interval=0.01), daemon=True
        )
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        connect = http.client.HTTPConnection.connect

        def delayed_connect(connection):
            time.sleep(0.35)
            connect(connection)

        with unittest.mock.patch("http.client.HTTPConnection.connect", delayed_connect):
            result = local_metadata_request(
                f"https://127.0.0.1:{server.server_address[1]}",
                "/suggest",
                self.token,
                maximum=4096,
                timeout=0.1,
            )
        self.assertIsNone(result)
        self.assertTrue(closed.wait(1.5))
        self.assertEqual(wire, [], "an expired TCP connection must not start TLS")

    def test_delayed_worker_preflight_never_starts_metadata_after_caller_timeout(self):
        url, state = self._start_server("normal")
        router = self._router_for_dripping_sidecar(url, local=True)

        def delayed_token():
            time.sleep(0.35)
            return self.token

        async def request():
            return await router._availability()

        with (
            unittest.mock.patch(
                "quotabot_router._load_local_http_token", delayed_token
            ),
            unittest.mock.patch("local_metadata.LOCAL_METADATA_TIMEOUT_SECONDS", 0.1),
        ):
            self.assertIsNone(asyncio.run(request()))
        self.assertEqual(
            state["requests"], [], "expired preflight must not restart its budget"
        )

    def _assert_delayed_tls_initialization_sends_nothing(self, *, asynchronous):
        accepted = Event()
        wire = []

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                accepted.set()
                self.request.settimeout(1.5)
                try:
                    while chunk := self.request.recv(4096):
                        wire.append(chunk)
                except ConnectionError:
                    pass

        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        thread = Thread(
            target=lambda: server.serve_forever(poll_interval=0.01), daemon=True
        )
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        create_context = ssl.create_default_context

        def delayed_context():
            time.sleep(0.35)
            return create_context()

        operation = functools.partial(
            local_metadata_request,
            f"https://127.0.0.1:{server.server_address[1]}",
            "/suggest",
            self.token,
            maximum=4096,
            timeout=0.5 if asynchronous else 0.1,
        )
        with (
            unittest.mock.patch(
                "local_metadata.ssl.create_default_context", delayed_context
            ),
            unittest.mock.patch("local_metadata.LOCAL_METADATA_TIMEOUT_SECONDS", 0.1),
        ):
            if asynchronous:
                result = asyncio.run(run_metadata_operation(operation))
            else:
                result = operation()
        self.assertIsNone(result)
        self.assertFalse(accepted.is_set(), "expired initialization must not connect")
        self.assertEqual(wire, [])

    def test_standalone_timeout_includes_tls_context_initialization(self):
        self._assert_delayed_tls_initialization_sends_nothing(asynchronous=False)

    def test_async_deadline_includes_tls_context_initialization(self):
        self._assert_delayed_tls_initialization_sends_nothing(asynchronous=True)

    def _assert_token_preflight_allows_heartbeat(self, *, reserve):
        router = QuotabotRouter()
        times = []
        beats = []

        def delayed_token():
            times.append(time.monotonic())
            time.sleep(0.3)
            times.append(time.monotonic())
            return self.token

        async def exercise():
            finished = asyncio.Event()

            async def heartbeat():
                while not finished.is_set():
                    beats.append(time.monotonic())
                    await asyncio.sleep(0.01)

            task = asyncio.create_task(heartbeat())
            await asyncio.sleep(0)
            try:
                if reserve:
                    await router._reserve_remote(
                        [
                            Candidate(
                                "fixed", provider="claude", account="synthetic-account"
                            )
                        ],
                        [],
                        15,
                        None,
                    )
                else:
                    await router._release_route_lease(
                        {"quotabot_lease_id": "synthetic-lease-0001"}
                    )
            finally:
                finished.set()
                await task

        with (
            unittest.mock.patch(
                "quotabot_router._load_local_http_token", delayed_token
            ),
            unittest.mock.patch.object(router, "_post_mutation", return_value=None),
        ):
            asyncio.run(exercise())
        self.assertEqual(len(times), 2)
        self.assertTrue(
            any(times[0] < beat < times[1] for beat in beats),
            "other async routing must progress while the token file is read",
        )

    def test_reservation_token_preflight_allows_event_loop_heartbeat(self):
        self._assert_token_preflight_allows_heartbeat(reserve=True)

    def test_release_token_preflight_allows_event_loop_heartbeat(self):
        self._assert_token_preflight_allows_heartbeat(reserve=False)

    def test_slow_mutation_token_preflight_never_dispatches_after_timeout(self):
        for reserve in (True, False):
            with self.subTest(reserve=reserve):
                url, state = self._start_server("normal")
                router = self._router_for_dripping_sidecar(url, local=True)

                def delayed_token():
                    time.sleep(0.35)
                    return self.token

                async def request():
                    if reserve:
                        return await router._reserve_remote(
                            [
                                Candidate(
                                    "fixed",
                                    provider="claude",
                                    account="synthetic-account",
                                )
                            ],
                            [],
                            15,
                            None,
                        )
                    return await router._release_route_lease(
                        {"quotabot_lease_id": "synthetic-lease-0001"}
                    )

                with (
                    unittest.mock.patch(
                        "quotabot_router._load_local_http_token", delayed_token
                    ),
                    unittest.mock.patch(
                        "local_metadata.LOCAL_METADATA_TIMEOUT_SECONDS", 0.1
                    ),
                ):
                    self.assertIsNone(asyncio.run(request()))
                self.assertEqual(
                    state["requests"], [], "expired token preflight must not dispatch"
                )

    def test_rejected_owned_lease_cleanup_reuses_original_token(self):
        router = QuotabotRouter()
        candidate = Candidate("fixed", provider="claude", account="synthetic-account")
        calls = []

        def mutation(path, payload, token):
            calls.append((path, token))
            if path == "/leases/release":
                return {"schema": "quotabot.release.v1", "released": True}
            return {
                "schema": "quotabot.reserve.v1",
                "reserved": True,
                "lease": {
                    "id": "synthetic-owned-lease-0001",
                    "provider": "claude",
                    "account": "wrong-account",
                    "client": "litellm",
                    "idempotency_key": payload["idempotency_key"],
                },
                "selected": {"provider": "claude", "account": "synthetic-account"},
            }

        with (
            unittest.mock.patch(
                "quotabot_router._load_local_http_token",
                side_effect=[self.token, "different-synthetic-token-0123456789"],
            ) as load_token,
            unittest.mock.patch.object(router, "_post_mutation", mutation),
        ):
            self.assertIsNone(
                asyncio.run(router._reserve_remote([candidate], [], 15, None))
            )
        load_token.assert_called_once_with()
        self.assertEqual(
            calls,
            [("/leases/reserve", self.token), ("/leases/release", self.token)],
        )

    def test_invalid_lease_id_does_not_read_token(self):
        router = QuotabotRouter()
        with (
            unittest.mock.patch("quotabot_router._load_local_http_token") as load_token,
            unittest.mock.patch.object(router, "_post_mutation") as mutation,
        ):
            asyncio.run(router._release_route_lease({"quotabot_lease_id": "invalid"}))
        load_token.assert_not_called()
        mutation.assert_not_called()


if __name__ == "__main__":
    unittest.main()
