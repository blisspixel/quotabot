import asyncio
import unittest

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


if __name__ == "__main__":
    unittest.main()
