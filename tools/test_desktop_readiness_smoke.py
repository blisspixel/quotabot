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
    REPORT_SCHEMA,
    SCHEMA,
    _read_json_if_ready,
    assert_bundle_unchanged,
    await_readiness,
    build_readiness_report,
    desktop_bundle_identity,
    desktop_bundle_root,
    executable_sha256,
    isolated_config_environment,
    launch_command,
    macos_app_process_ids,
    stop_process,
    valid_windows_tray_rect,
    validate_report_destination,
    validate_payload,
    write_report,
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
                "--env",
                "XDG_CONFIG_HOME=/tmp/config",
                "/tmp/quotabot.app",
            ],
        )

    def test_isolates_candidate_config_without_replacing_home(self) -> None:
        root = Path("C:/isolated/config")

        self.assertEqual(
            isolated_config_environment("windows", root),
            {
                "XDG_CONFIG_HOME": str(root),
                "LOCALAPPDATA": str(root),
                "APPDATA": str(root),
            },
        )
        self.assertEqual(
            isolated_config_environment("linux", root),
            {"XDG_CONFIG_HOME": str(root)},
        )
        self.assertNotIn("HOME", isolated_config_environment("macos", root))

    def test_selects_the_complete_platform_bundle_root(self) -> None:
        windows = Path("C:/build/Release/quotabot.exe")
        macos = Path("/tmp/quotabot.app/Contents/MacOS/quotabot")

        self.assertEqual(desktop_bundle_root(windows, "windows"), windows.parent)
        self.assertEqual(desktop_bundle_root(macos, "macos"), Path("/tmp/quotabot.app"))
        with self.assertRaisesRegex(RuntimeError, "not inside an app bundle"):
            desktop_bundle_root(Path("/tmp/quotabot"), "macos")

    def test_bundle_identity_is_order_independent_and_tracks_payload(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temporary = Path(raw_temp)
            first = temporary / "first"
            second = temporary / "second"
            (first / "data").mkdir(parents=True)
            (first / "quotabot.exe").write_bytes(b"stable runner")
            (first / "data" / "app.so").write_bytes(b"version one")
            (second / "data").mkdir(parents=True)
            (second / "data" / "app.so").write_bytes(b"version one")
            (second / "quotabot.exe").write_bytes(b"stable runner")

            first_executable = first / "quotabot.exe"
            second_executable = second / "quotabot.exe"
            first_identity = desktop_bundle_identity(first_executable, "windows")
            second_identity = desktop_bundle_identity(second_executable, "windows")

            self.assertEqual(first_identity, second_identity)
            self.assertEqual(first_identity["bundle_entry_count"], 2)
            self.assertEqual(
                first_identity["bundle_bytes"], len(b"stable runnerversion one")
            )

            (second / "data" / "app.so").write_bytes(b"version two")
            changed_identity = desktop_bundle_identity(second_executable, "windows")

            self.assertEqual(
                executable_sha256(first_executable),
                executable_sha256(second_executable),
            )
            self.assertNotEqual(
                first_identity["bundle_sha256"],
                changed_identity["bundle_sha256"],
            )

    def test_bundle_identity_enforces_entry_and_byte_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temporary = Path(raw_temp)
            executable = temporary / "quotabot"
            executable.write_bytes(b"candidate")
            (temporary / "data").mkdir()
            (temporary / "data" / "app.so").write_bytes(b"payload")

            with self.assertRaisesRegex(RuntimeError, "entry limit"):
                desktop_bundle_identity(
                    executable,
                    "linux",
                    max_entries=1,
                )
            with self.assertRaisesRegex(RuntimeError, "byte limit"):
                desktop_bundle_identity(
                    executable,
                    "linux",
                    max_bytes=1,
                )

    @unittest.skipIf(os.name == "nt", "ordinary Windows users cannot create links")
    def test_bundle_identity_hashes_link_metadata_without_following_it(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temporary = Path(raw_temp)
            bundle = temporary / "bundle"
            bundle.mkdir()
            executable = bundle / "quotabot"
            executable.write_bytes(b"candidate")
            outside = temporary / "outside"
            outside.write_bytes(b"first external payload")
            (bundle / "external").symlink_to(outside)

            first = desktop_bundle_identity(executable, "linux")
            outside.write_bytes(b"changed external payload")
            second = desktop_bundle_identity(executable, "linux")

            self.assertEqual(first, second)
            self.assertEqual(first["bundle_bytes"], len(b"candidate"))

    def test_rejects_a_bundle_changed_during_readiness(self) -> None:
        identity = {
            "bundle_sha256": "a" * 64,
            "bundle_entry_count": 2,
            "bundle_bytes": 20,
        }

        assert_bundle_unchanged(identity, dict(identity))
        with self.assertRaisesRegex(RuntimeError, "changed during readiness"):
            assert_bundle_unchanged(
                identity,
                {**identity, "bundle_sha256": "b" * 64},
            )

    def test_requires_the_report_to_stay_outside_the_candidate_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temporary = Path(raw_temp)
            bundle = temporary / "bundle"
            bundle.mkdir()

            validate_report_destination(temporary / "report.json", bundle)
            with self.assertRaisesRegex(RuntimeError, "outside the bundle"):
                validate_report_destination(bundle / "report.json", bundle)

    def test_builds_and_writes_bounded_readiness_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temporary = Path(raw_temp)
            executable = temporary / "quotabot.exe"
            executable.write_bytes(b"candidate")
            identity = desktop_bundle_identity(executable, "windows")
            report = build_readiness_report(
                "windows",
                31415,
                executable,
                identity,
            )
            destination = temporary / "readiness-report.json"

            write_report(destination, report)

            written = json.loads(destination.read_text(encoding="utf-8"))
            generated_at = written.pop("generated_at")
            self.assertRegex(
                generated_at,
                r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}\+00:00$",
            )
            self.assertEqual(
                written,
                {
                    "schema": REPORT_SCHEMA,
                    "platform": "windows",
                    "launch_pid": 31415,
                    "launch_process_stopped": True,
                    "executable_name": "quotabot.exe",
                    "executable_sha256": (
                        "dda18a0e21ae47c53b4309434cbc02ae8bf764fa83a6defbb719431242722aa7"
                    ),
                    "bundle_sha256": identity["bundle_sha256"],
                    "bundle_schema": identity["bundle_schema"],
                    "bundle_entry_count": 1,
                    "bundle_bytes": len(b"candidate"),
                    "bundle_unchanged": True,
                    "isolated_config": True,
                    "window_ready": True,
                    "tray_ready": True,
                },
            )
            self.assertEqual(list(temporary.glob(".*.tmp")), [])

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
            unittest.mock.patch("tools.desktop_readiness_smoke.os.name", "nt"),
            unittest.mock.patch("tools.desktop_readiness_smoke.subprocess.run") as run,
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
            unittest.mock.patch("tools.desktop_readiness_smoke.os.name", "nt"),
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
