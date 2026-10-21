"""Pure display mapping tests. These tests do not run quotabot or touch home."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


def _load(name: str):
    path = Path(__file__).resolve().parent / "plugin" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"quotabot_omarchy_{name}", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


display = _load("display")
HOME = Path("/home/secretuser")
KEY = b"\x11" * 32


def _snapshot() -> dict[str, object]:
    return {
        "schema": "quotabot.v1",
        "generated_at": 1_800_000_000,
        "snapshot_source": "live",
        "providers": [
            {
                "provider": "claude",
                "display_name": "Claude",
                "account": "person@example.com",
                "kind": "subscription",
                "plan": "Max",
                "source_class": "authoritative_live",
                "ok": True,
                "stale": False,
                "as_of": 1_800_000_000,
                "windows": [
                    {
                        "label": "5h",
                        "used_percent": 20,
                        "resets_at": 1_800_003_600,
                    },
                    {
                        "label": "week",
                        "used_percent": 40,
                        "resets_at": 1_800_600_000,
                    },
                ],
                "details": {"token": "sk-supersecretvalue1234567890"},
                "models": [{"id": "hidden"}],
                "local_hardware": {"gpu": "hidden"},
            },
            {
                "provider": "codex",
                "display_name": "Codex",
                "account": "other@example.com",
                "kind": "subscription",
                "source_class": "authoritative_live",
                "ok": False,
                "error": f"signin failed for other@example.com in {HOME}/.codex",
                "stale": False,
                "windows": [],
            },
        ],
    }


def _suggestion() -> dict[str, object]:
    return {
        "schema": "quotabot.suggest.v1",
        "as_of": 1_800_000_010,
        "decision_code": "balanced_headroom",
        "routing_policy": "balanced",
        "reason": "Claude has the most remaining included quota.",
        "explanation": "Account person@example.com should stay out of the panel.",
        "recommended": {
            "provider": "claude",
            "account": "person@example.com",
            "headroom_percent": 60,
            "effective_headroom_percent": 58,
            "resets_at": 1_800_600_000,
            "stale": False,
            "available": True,
            "local": False,
        },
        "fallback": {
            "kind": "local",
            "provider": "ollama",
            "reason": "Use a local runtime if Claude is skipped.",
        },
        "ranked": [],
        "receipt": {
            "account": "person@example.com",
            "secret": "Bearer abcdefghijklmnop",
        },
    }


class DisplayTests(unittest.TestCase):
    def test_recommendation_comes_from_suggest_and_keeps_failed_provider(self) -> None:
        record = display.build_display(
            _snapshot(),
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        self.assertEqual(record["schema"], "quotabot.omarchy.v1")
        self.assertTrue(record["read_ok"])
        recommendation = record["recommendation"]
        self.assertIsInstance(recommendation, dict)
        assert isinstance(recommendation, dict)
        self.assertEqual(recommendation["provider"], "claude")
        self.assertEqual(recommendation["headroom_percent"], 58)
        self.assertEqual(recommendation["freshness"], "live")
        self.assertNotIn("@", str(recommendation["account_label"]))
        accounts = record["accounts"]
        self.assertIsInstance(accounts, list)
        assert isinstance(accounts, list)
        by_provider = {item["provider"]: item for item in accounts}
        self.assertEqual(by_provider["claude"]["headroom_percent"], 60)
        self.assertEqual(by_provider["claude"]["freshness"], "live")
        self.assertEqual(by_provider["claude"]["resets_at"], 1_800_600_000)
        self.assertTrue(by_provider["claude"]["routable"])
        self.assertIsNone(by_provider["codex"]["headroom_percent"])
        self.assertEqual(by_provider["codex"]["freshness"], "unknown")
        self.assertFalse(by_provider["codex"]["routable"])
        fallback = record["fallback"]
        self.assertIsInstance(fallback, dict)
        assert isinstance(fallback, dict)
        self.assertEqual(fallback["kind"], "local")
        self.assertTrue(fallback["local"])

    def test_redacts_accounts_secrets_paths_and_drops_receipt(self) -> None:
        record = display.build_display(
            _snapshot(),
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        encoded = str(record)
        self.assertNotIn("example.com", encoded)
        self.assertNotIn("person@", encoded)
        self.assertNotIn("sk-super", encoded)
        self.assertNotIn("Bearer", encoded)
        self.assertNotIn("secretuser", encoded)
        self.assertNotIn("receipt", encoded)
        self.assertNotIn("local_hardware", encoded)
        self.assertNotIn("explanation", record)
        self.assertNotIn("models", encoded)
        first = display.account_label("claude", "person@example.com", KEY)
        second = display.account_label("claude", "person@example.com", KEY)
        other = display.account_label("claude", "other@example.com", KEY)
        self.assertEqual(first, second)
        self.assertNotEqual(first, other)
        self.assertTrue(str(first).startswith("account:"))

    def test_out_of_range_percent_is_drift_without_a_meter(self) -> None:
        snapshot = _snapshot()
        providers = snapshot["providers"]
        assert isinstance(providers, list)
        providers[0]["windows"] = [
            {"label": "week", "used_percent": 140, "resets_at": 1_800_600_000}
        ]
        record = display.build_display(
            snapshot,
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        accounts = record["accounts"]
        assert isinstance(accounts, list)
        claude = next(item for item in accounts if item["provider"] == "claude")
        self.assertEqual(claude["freshness"], "drift")
        self.assertIsNone(claude["headroom_percent"])
        self.assertFalse(claude["routable"])
        self.assertIsNone(claude["windows"][0]["used_percent"])

    def test_drift_reason_withholds_remaining_headroom(self) -> None:
        snapshot = _snapshot()
        providers = snapshot["providers"]
        assert isinstance(providers, list)
        providers[0]["drift_reason"] = "reset advanced"
        record = display.build_display(
            snapshot,
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        accounts = record["accounts"]
        assert isinstance(accounts, list)
        claude = next(item for item in accounts if item["provider"] == "claude")
        self.assertEqual(claude["freshness"], "drift")
        self.assertIsNone(claude["headroom_percent"])
        self.assertEqual(claude["windows"][0]["used_percent"], 20)

    def test_stale_last_trusted_window_stays_labeled_stale(self) -> None:
        snapshot = _snapshot()
        providers = snapshot["providers"]
        assert isinstance(providers, list)
        providers[0]["stale"] = True
        record = display.build_display(
            snapshot,
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        accounts = record["accounts"]
        assert isinstance(accounts, list)
        claude = next(item for item in accounts if item["provider"] == "claude")
        self.assertEqual(claude["freshness"], "stale")
        self.assertEqual(claude["headroom_percent"], 60)
        self.assertFalse(claude["routable"])

    def test_manual_quota_is_not_routable(self) -> None:
        snapshot = _snapshot()
        providers = snapshot["providers"]
        assert isinstance(providers, list)
        providers[0]["source_class"] = "manual"
        record = display.build_display(
            snapshot,
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        accounts = record["accounts"]
        assert isinstance(accounts, list)
        claude = next(item for item in accounts if item["provider"] == "claude")
        self.assertEqual(claude["source_class"], "manual")
        self.assertFalse(claude["routable"])

    def test_local_readiness_is_kept_only_for_a_local_candidate(self) -> None:
        suggestion = _suggestion()
        recommended = suggestion["recommended"]
        assert isinstance(recommended, dict)
        recommended["local"] = True
        recommended["provider"] = "ollama"
        recommended["local_readiness"] = "loaded"
        recommended["account"] = "default"
        record = display.build_display(
            _snapshot(),
            suggestion,
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        recommendation = record["recommendation"]
        assert isinstance(recommendation, dict)
        self.assertTrue(recommendation["local"])
        self.assertEqual(recommendation["local_readiness"], "loaded")
        self.assertEqual(recommendation["account_label"], "default")

    def test_failed_read_preserves_previous_meters(self) -> None:
        previous = display.build_display(
            _snapshot(),
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        failed = display.preserve_failure(
            previous,
            "quotabot timed out",
            now=1_800_000_100,
            home=HOME,
        )
        self.assertFalse(failed["read_ok"])
        self.assertEqual(failed["read_error"], "quotabot timed out")
        self.assertEqual(failed["accounts"], previous["accounts"])
        self.assertEqual(failed["recommendation"], previous["recommendation"])
        self.assertEqual(failed["generated_at"], previous["generated_at"])
        self.assertEqual(failed["snapshot_as_of"], previous["snapshot_as_of"])
        self.assertEqual(failed["suggestion_as_of"], previous["suggestion_as_of"])
        self.assertEqual(failed["read_failed_at"], 1_800_000_100)

    def test_present_display_ages_old_live_evidence_without_rewriting_it(self) -> None:
        record = display.build_display(
            _snapshot(),
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        captured = record["snapshot_as_of"]
        aged = display.present_display(record, now=1_800_000_020 + 86_400)
        account = aged["accounts"][0]
        recommendation = aged["recommendation"]
        assert isinstance(account, dict)
        assert isinstance(recommendation, dict)
        self.assertEqual(account["freshness"], "stale")
        self.assertEqual(account["headroom_percent"], 60.0)
        self.assertFalse(account["routable"])
        self.assertEqual(account["evidence_age_seconds"], 86_400 + 20)
        self.assertEqual(recommendation["freshness"], "stale")
        self.assertEqual(recommendation["headroom_percent"], 58)
        self.assertFalse(recommendation["available"])
        self.assertEqual(record["accounts"][0]["freshness"], "live")
        self.assertEqual(record["snapshot_as_of"], captured)
        self.assertEqual(aged["snapshot_as_of"], captured)
        self.assertEqual(aged["generated_at"], record["generated_at"])

    def test_present_display_keeps_a_fresh_live_row(self) -> None:
        record = display.build_display(
            _snapshot(),
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        aged = display.present_display(record, now=1_800_000_020 + 100)
        account = aged["accounts"][0]
        assert isinstance(account, dict)
        self.assertEqual(account["freshness"], "live")
        self.assertTrue(account["routable"])
        self.assertEqual(account["evidence_age_seconds"], 120)

    def test_present_display_rejects_missing_time_and_future_skew(self) -> None:
        record = display.build_display(
            _snapshot(),
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        record["snapshot_as_of"] = None
        record["suggestion_as_of"] = None
        record["accounts"][0]["as_of"] = None
        missing = display.present_display(record, now=1_800_000_020)
        account = missing["accounts"][0]
        assert isinstance(account, dict)
        self.assertEqual(account["freshness"], "stale")
        self.assertIsNone(account["evidence_age_seconds"])
        self.assertEqual(account["headroom_percent"], 60.0)
        self.assertIsNone(missing["evidence_as_of"])

        skewed = display.present_display(
            display.build_display(
                _snapshot(),
                _suggestion(),
                now=1_800_000_020,
                alias_key=KEY,
                home=HOME,
            ),
            now=1_800_000_000 - (display.FUTURE_SKEW_SECONDS + 1),
        )
        skewed_account = skewed["accounts"][0]
        assert isinstance(skewed_account, dict)
        self.assertEqual(skewed_account["freshness"], "stale")
        self.assertIsNone(skewed_account["evidence_age_seconds"])

    def test_present_display_leaves_drift_and_unknown_unchanged(self) -> None:
        record = display.build_display(
            _snapshot(),
            _suggestion(),
            now=1_800_000_020,
            alias_key=KEY,
            home=HOME,
        )
        record["accounts"][0]["freshness"] = "drift"
        record["accounts"][0]["headroom_percent"] = None
        record["accounts"][1]["freshness"] = "unknown"
        record["accounts"][1]["headroom_percent"] = None
        aged = display.present_display(record, now=1_800_000_020 + 86_400)
        drift = aged["accounts"][0]
        unknown = aged["accounts"][1]
        assert isinstance(drift, dict)
        assert isinstance(unknown, dict)
        self.assertEqual(drift["freshness"], "drift")
        self.assertIsNone(drift["headroom_percent"])
        self.assertEqual(unknown["freshness"], "unknown")
        self.assertIsNone(unknown["headroom_percent"])
        empty = display.preserve_failure(
            {"schema": "other"},
            "missing",
            now=1_800_000_100,
            home=HOME,
        )
        self.assertEqual(empty["accounts"], [])
        self.assertIsNone(empty["recommendation"])


if __name__ == "__main__":
    unittest.main()
