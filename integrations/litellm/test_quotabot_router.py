import asyncio
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
                "frontier": [Candidate(deployment="claude-sonnet", provider="claude")]
            },
            agents={"spoofed-agent": AgentRule(pin="grok-fast")},
        )
        chosen = asyncio.run(
            router._route("frontier", {"metadata": {"agent": "spoofed-agent"}}, None)
        )
        self.assertEqual(chosen, "frontier")

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

    def test_agent_model_redirect_uses_trusted_key_alias(self):
        router = QuotabotRouter()
        router.policy = Policy(
            models={
                "bulk": [Candidate(deployment="ollama-qwen", local=True)],
                "frontier": [Candidate(deployment="claude-sonnet", provider="claude")],
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


if __name__ == "__main__":
    unittest.main()
