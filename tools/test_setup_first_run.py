import json
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path

from tools.setup_first_run import render_first_run


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "setup_first_run.py"
POWERSHELL_SCRIPT = ROOT / "tools" / "setup_first_run.ps1"
NOW = 2_000_000_000


def provider(
    key: str,
    *,
    name: str | None = None,
    ok: bool = True,
    error: str | None = None,
    stale: bool = False,
    source_class: str = "authoritative_live",
    kind: str = "subscription",
    windows: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    row: dict[str, object] = {
        "provider": key,
        "display_name": name or key.title(),
        "account": "default",
        "ok": ok,
        "stale": stale,
        "source_class": source_class,
        "kind": kind,
        "as_of": NOW,
        "windows": windows
        if windows is not None
        else [{"label": "weekly", "used_percent": 10, "resets_at": NOW + 3600}],
    }
    if error is not None:
        row["error"] = error
    return row


class SetupFirstRunTests(unittest.TestCase):
    def test_renders_live_login_and_diagnostic_rows_without_false_reassurance(
        self,
    ) -> None:
        snapshot = {
            "providers": [
                provider("claude", name="Claude"),
                provider(
                    "codex",
                    name="Codex",
                    ok=False,
                    error="Run quotabot login codex to connect",
                ),
                provider(
                    "grok",
                    name="Grok",
                    ok=False,
                    error="invalid Grok usage response",
                ),
            ]
        }

        output = render_first_run(snapshot, now=NOW)

        self.assertIn("Already live (no extra login): Claude", output)
        self.assertIn("quotabot login codex", output)
        self.assertIn("Grok - signed in, quota unreadable", output)
        self.assertNotIn("No extra login required", output)
        self.assertNotIn("Grok (signed in)", output)

    def test_stale_expired_detection_only_and_manual_rows_are_not_live(self) -> None:
        snapshot = {
            "providers": [
                provider("claude", name="Claude", stale=True),
                provider(
                    "codex",
                    name="Codex",
                    windows=[
                        {
                            "label": "weekly",
                            "used_percent": 10,
                            "resets_at": NOW,
                        }
                    ],
                ),
                provider(
                    "cursor",
                    name="Cursor",
                    source_class="passive_local_evidence",
                    windows=[],
                ),
                provider("custom", name="Custom", source_class="manual"),
            ]
        }

        output = render_first_run(snapshot, now=NOW)

        self.assertNotIn("Already live", output)
        self.assertEqual(output.count("no fresh quota evidence"), 4)
        self.assertNotIn("No extra login required", output)

    def test_suspect_drifted_future_and_malformed_windows_are_not_live(self) -> None:
        suspect = provider("claude", name="Claude")
        suspect["suspect"] = "implausible movement"
        drifted = provider("codex", name="Codex")
        drifted["drift_reason"] = "schema drift"
        future = provider("grok", name="Grok")
        future["as_of"] = NOW + 61
        malformed = provider(
            "antigravity",
            name="Antigravity",
            windows=[{"label": "weekly", "used_percent": 101}],
        )

        output = render_first_run(
            {"providers": [suspect, drifted, future, malformed]}, now=NOW
        )

        self.assertNotIn("Already live", output)
        self.assertEqual(output.count("no fresh quota evidence"), 4)

    def test_local_and_status_only_rows_are_ready_when_fresh(self) -> None:
        snapshot = {
            "providers": [
                provider(
                    "ollama",
                    name="Ollama",
                    source_class="local_runtime",
                    kind="local",
                    windows=[],
                ),
                provider(
                    "nvidia",
                    name="NVIDIA NIM",
                    source_class="status_only",
                    windows=[],
                ),
                provider(
                    "lemonade",
                    name="Lemonade",
                    source_class="local_runtime",
                    kind="local",
                    windows=[],
                ),
            ]
        }
        snapshot["providers"][0]["models"] = [{"id": "llama", "local": True}]
        snapshot["providers"][2]["models"] = [
            {"id": "remote", "local": True, "cloud_offloaded": True}
        ]

        output = render_first_run(snapshot, now=NOW)

        self.assertIn("Already live (no extra login): Ollama", output)
        self.assertIn("NVIDIA NIM - no fresh quota evidence", output)
        self.assertIn("Lemonade - no fresh quota evidence", output)
        self.assertNotIn("No extra login required", output)

    def test_a_live_account_hides_a_sibling_login_for_the_same_provider(self) -> None:
        live = provider("claude", name="Claude")
        stale_login = provider(
            "claude",
            name="Claude",
            ok=False,
            error="quotabot login claude",
        )
        stale_login["account"] = "personal"
        output = render_first_run({"providers": [stale_login, live]}, now=NOW)
        self.assertIn("Already live (no extra login): Claude", output)
        self.assertNotIn("quotabot login claude", output)

    def test_deduplicates_multi_account_output(self) -> None:
        live = provider("claude", name="Claude")
        second = dict(live)
        second["account"] = "work"
        login = provider(
            "codex",
            name="Codex",
            ok=False,
            error="quotabot login codex",
        )

        output = render_first_run(
            {"providers": [live, second, login, dict(login)]},
            now=NOW,
        )

        self.assertEqual(output.count("Already live (no extra login): Claude"), 1)
        self.assertEqual(output.count("quotabot login codex"), 1)

    def test_cli_reads_snapshot_from_stdin_and_malformed_input_is_quiet(self) -> None:
        snapshot = {"providers": [provider("claude", name="Claude")]}
        completed = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=json.dumps(snapshot),
            text=True,
            capture_output=True,
            check=False,
        )
        malformed = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input="not-json",
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0)
        self.assertIn("First run", completed.stdout)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(malformed.returncode, 0)
        self.assertEqual(malformed.stdout, "")
        self.assertEqual(malformed.stderr, "")

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is not installed")
    def test_powershell_renderer_matches_readiness_boundaries(self) -> None:
        current = int(time.time())
        snapshot = {
            "providers": [
                provider("claude", name="Claude"),
                provider("codex", name="Codex", stale=True),
                provider(
                    "grok",
                    name="Grok",
                    ok=False,
                    error="invalid Grok usage response",
                ),
            ]
        }
        for row in snapshot["providers"]:
            row["as_of"] = current
            for window in row["windows"]:
                window["resets_at"] = current + 3600
        completed = subprocess.run(
            [
                shutil.which("pwsh") or "pwsh",
                "-NoProfile",
                "-File",
                str(POWERSHELL_SCRIPT),
            ],
            input=json.dumps(snapshot),
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Already live (no extra login): Claude", completed.stdout)
        self.assertIn("Codex - no fresh quota evidence", completed.stdout)
        self.assertIn("Grok - signed in, quota unreadable", completed.stdout)
        self.assertNotIn("No extra login required", completed.stdout)


if __name__ == "__main__":
    unittest.main()
