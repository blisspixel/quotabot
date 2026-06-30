import asyncio
import json
import tempfile
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from quotabot_router import (
    AgentRule,
    Candidate,
    Policy,
    QuotabotRouter,
    UnsafeRouteError,
    _is_loopback_url,
)


class _Key:
    key_alias = "trusted-agent"
    user_id = None


class RouterTests(unittest.TestCase):
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

    def test_quota_plan_candidates_are_allowed_by_default(self):
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
        self.assertEqual(chosen, "claude-subscription")

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

        policy = Policy(quotabot_url="http://169.254.169.254/latest")
        self.assertEqual(policy.quotabot_url, "http://127.0.0.1:8721")

    def test_fetch_suggest_does_not_follow_redirects(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:9/redirected")
                self.end_headers()

            def log_message(self, format, *args):
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        router = QuotabotRouter()
        router.policy = Policy(quotabot_url=f"http://127.0.0.1:{server.server_port}")
        self.assertIsNone(router._fetch_suggest())

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
models:
  frontier:
    candidates:
      - deployment: xai-api
        provider: grok
        spend: paid_api
agents:
  architect:
    pin: claude-subscription
    pin_spend: quota_plan
""",
                encoding="utf-8",
            )

            policy = Policy.load(path)

        self.assertTrue(policy.allow_paid_api)
        self.assertFalse(policy.block_unsafe_passthrough)
        self.assertEqual(policy.models["frontier"][0].spend, "paid_api")
        self.assertEqual(policy.agents["architect"].pin_spend, "quota_plan")

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

            asyncio.run(
                router.async_log_success_event(
                    {
                        "model": "ollama-qwen",
                        "response_cost": 0,
                        "litellm_params": {
                            "metadata": {
                                "quotabot_original_model": "cheap-bulk",
                                "quotabot_spend": "local",
                            }
                        },
                    },
                    Response(),
                    None,
                    None,
                )
            )

            record = json.loads(path.read_text(encoding="utf-8").strip())

        self.assertEqual(record["requested_model"], "cheap-bulk")
        self.assertEqual(record["served_model"], "ollama-qwen")
        self.assertEqual(record["spend"], "local")
        self.assertEqual(record["prompt_tokens"], 10)


if __name__ == "__main__":
    unittest.main()
