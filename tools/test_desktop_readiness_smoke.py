import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from tools.desktop_readiness_smoke import (
    SCHEMA,
    await_readiness,
    stop_process,
    valid_windows_tray_rect,
    validate_payload,
)


class DesktopReadinessTests(unittest.TestCase):
    def test_accepts_exact_ready_payload(self) -> None:
        validate_payload(
            {
                "schema": SCHEMA,
                "window_ready": True,
                "tray_ready": True,
                "platform": "linux",
            },
            "linux",
        )

    def test_rejects_failed_tray_initialization(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "ready native window and tray"):
            validate_payload(
                {
                    "schema": SCHEMA,
                    "window_ready": True,
                    "tray_ready": False,
                    "platform": "linux",
                },
                "linux",
            )

    def test_requires_a_successful_nonempty_windows_tray_rectangle(self) -> None:
        rect = SimpleNamespace(left=10, top=20, right=30, bottom=40)
        self.assertTrue(valid_windows_tray_rect(0, rect))
        self.assertFalse(valid_windows_tray_rect(-1, rect))
        self.assertFalse(
            valid_windows_tray_rect(
                0,
                SimpleNamespace(left=10, top=20, right=10, bottom=40),
            )
        )

    def test_awaits_a_complete_readiness_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            readiness_file = Path(raw_temp) / "readiness.json"
            readiness_file.write_text(
                json.dumps(
                    {
                        "schema": SCHEMA,
                        "window_ready": True,
                        "tray_ready": True,
                        "platform": "windows",
                    }
                ),
                encoding="utf-8",
            )
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(5)"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                await_readiness(process, readiness_file, "windows", 1)
            finally:
                process.terminate()
                process.wait(timeout=5)

    @unittest.skipIf(os.name == "nt", "POSIX process-group behavior")
    def test_stops_the_entire_posix_process_group(self) -> None:
        process = mock.Mock(pid=31415)
        process.wait.return_value = 0

        with mock.patch("tools.desktop_readiness_smoke.os.killpg") as kill_group:
            stop_process(process)

        kill_group.assert_called_once_with(31415, signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=5)


if __name__ == "__main__":
    unittest.main()
