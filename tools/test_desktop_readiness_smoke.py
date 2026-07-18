import json
import os
from pathlib import Path, PurePosixPath
import signal
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
import unittest.mock

from tools.desktop_readiness_smoke import (
    SCHEMA,
    _read_json_if_ready,
    await_readiness,
    launch_command,
    macos_app_process_ids,
    stop_process,
    valid_windows_tray_rect,
    validate_payload,
)


class DesktopReadinessTests(unittest.TestCase):
    def test_launches_macos_through_the_app_bundle(self) -> None:
        executable = PurePosixPath("/tmp/quotabot.app/Contents/MacOS/quotabot")
        readiness_file = PurePosixPath("/tmp/readiness.json")

        self.assertEqual(
            launch_command(executable, "macos", readiness_file),
            [
                "/usr/bin/open",
                "-n",
                "-W",
                "--env",
                "QUOTABOT_DESKTOP_READINESS_FILE=/tmp/readiness.json",
                "--env",
                "QUOTABOT_DEMO=1",
                "/tmp/quotabot.app",
            ],
        )

    def test_selects_only_the_exact_macos_bundle_executable(self) -> None:
        executable = PurePosixPath(
            "/tmp/build with spaces/quotabot.app/Contents/MacOS/quotabot"
        )
        process_table = """
          101 /tmp/build with spaces/quotabot.app/Contents/MacOS/quotabot
          102 /tmp/build with spaces/quotabot.app/Contents/MacOS/quotabot --flag
          103 /Applications/quotabot.app/Contents/MacOS/quotabot
          104 /tmp/build with spaces/quotabot.app/Contents/MacOS/quotabot-helper
        """

        self.assertEqual(macos_app_process_ids(process_table, executable), [101, 102])

    def test_accepts_exact_ready_payload(self) -> None:
        self.assertTrue(
            validate_payload(
                {
                    "schema": SCHEMA,
                    "window_ready": True,
                    "tray_ready": True,
                    "platform": "linux",
                },
                "linux",
            )
        )

    def test_accepts_incomplete_progress_without_declaring_ready(self) -> None:
        self.assertFalse(
            validate_payload(
                {
                    "schema": SCHEMA,
                    "window_ready": False,
                    "tray_ready": None,
                    "platform": "macos",
                },
                "macos",
            )
        )

    def test_rejects_failed_tray_initialization(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "failed tray initialization"):
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

    def test_polls_from_immutable_progress_to_complete_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            readiness_file = Path(raw_temp) / "readiness.json"
            progress_file = Path(f"{readiness_file}.window.json")
            progress_file.write_text(
                json.dumps(
                    {
                        "schema": SCHEMA,
                        "window_ready": True,
                        "tray_ready": None,
                        "platform": "linux",
                    }
                ),
                encoding="utf-8",
            )
            complete_payload = json.dumps(
                {
                    "schema": SCHEMA,
                    "window_ready": True,
                    "tray_ready": True,
                    "platform": "linux",
                }
            )
            writer = threading.Timer(
                0.05,
                readiness_file.write_text,
                args=(complete_payload,),
                kwargs={"encoding": "utf-8"},
            )
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(5)"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            writer.start()
            try:
                await_readiness(process, readiness_file, "linux", 1)
            finally:
                writer.join(timeout=1)
                process.terminate()
                process.wait(timeout=5)

    def test_polls_through_a_partial_write_to_complete_readiness(self) -> None:
        # The desktop app may be mid-write when the poll reads the file. A
        # truncated (invalid) readiness file must be treated as not-ready-yet
        # and retried, not raised as a hard failure - the real flaky-CI race.
        with tempfile.TemporaryDirectory() as raw_temp:
            readiness_file = Path(raw_temp) / "readiness.json"
            readiness_file.write_text('{"schema": "quotabot.des', encoding="utf-8")
            complete_payload = json.dumps(
                {
                    "schema": SCHEMA,
                    "window_ready": True,
                    "tray_ready": True,
                    "platform": "windows",
                }
            )
            writer = threading.Timer(
                0.05,
                readiness_file.write_text,
                args=(complete_payload,),
                kwargs={"encoding": "utf-8"},
            )
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(5)"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            writer.start()
            try:
                await_readiness(process, readiness_file, "windows", 1)
            finally:
                writer.join(timeout=1)
                process.terminate()
                process.wait(timeout=5)

    def test_read_json_if_ready_treats_a_share_lock_as_not_ready(self) -> None:
        # A Windows share lock during the app's write surfaces as PermissionError
        # (an OSError); the reader must report "not ready yet", never raise.
        with tempfile.TemporaryDirectory() as raw_temp:
            path = Path(raw_temp) / "readiness.json"
            path.write_text("{}", encoding="utf-8")
            with unittest.mock.patch.object(
                Path, "read_text", side_effect=PermissionError(13, "locked")
            ):
                self.assertIsNone(_read_json_if_ready(path))
            # A clean read still parses.
            self.assertEqual(_read_json_if_ready(path), {})
            # A missing file is not-ready, not an error.
            self.assertIsNone(_read_json_if_ready(Path(raw_temp) / "absent.json"))

    def test_windows_stop_waits_for_taskkill_to_release_log_handle(self) -> None:
        process = unittest.mock.Mock(pid=31415)
        process.poll.return_value = None
        process.wait.return_value = 0

        with (
            unittest.mock.patch(
                "tools.desktop_readiness_smoke.os.name", "nt"
            ),
            unittest.mock.patch(
                "tools.desktop_readiness_smoke.subprocess.run"
            ) as run,
        ):
            stop_process(process)

        run.assert_called_once_with(
            ["taskkill", "/PID", "31415", "/T", "/F"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        process.wait.assert_called_once_with(timeout=5)
        process.kill.assert_not_called()

    def test_windows_stop_force_kills_a_process_that_does_not_settle(self) -> None:
        process = unittest.mock.Mock(pid=31415)
        process.poll.return_value = None
        process.wait.side_effect = [
            subprocess.TimeoutExpired(["quotabot.exe"], 5),
            0,
        ]

        with (
            unittest.mock.patch(
                "tools.desktop_readiness_smoke.os.name", "nt"
            ),
            unittest.mock.patch("tools.desktop_readiness_smoke.subprocess.run"),
        ):
            stop_process(process)

        process.kill.assert_called_once_with()
        self.assertEqual(
            process.wait.call_args_list,
            [unittest.mock.call(timeout=5), unittest.mock.call(timeout=5)],
        )

    @unittest.skipIf(os.name == "nt", "POSIX process-group behavior")
    def test_stops_the_entire_posix_process_group(self) -> None:
        process = unittest.mock.Mock(pid=31415)
        process.wait.return_value = 0

        with unittest.mock.patch(
            "tools.desktop_readiness_smoke.os.killpg"
        ) as kill_group:
            stop_process(process)

        kill_group.assert_called_once_with(31415, signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=5)


if __name__ == "__main__":
    unittest.main()
