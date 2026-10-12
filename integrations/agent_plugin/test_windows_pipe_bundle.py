"""Native Windows pipe and complete-bundle regressions, without collection."""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


EXECUTABLE = os.environ.get("QUOTABOT_PLUGIN_TEST_EXECUTABLE")


def isolated_environment(profile: Path) -> dict[str, str]:
    environment = {
        key: os.environ[key]
        for key in ("PATH", "SystemRoot", "SYSTEMROOT", "WINDIR")
        if key in os.environ
    }
    environment.update(
        {
            key: str(profile)
            for key in (
                "HOME",
                "USERPROFILE",
                "LOCALAPPDATA",
                "APPDATA",
                "XDG_CONFIG_HOME",
                "XDG_CACHE_HOME",
                "TEMP",
                "TMP",
            )
        }
    )
    return environment


@unittest.skipUnless(os.name == "nt" and EXECUTABLE, "Windows native bundle required")
class WindowsPipeBundleTests(unittest.TestCase):
    def test_synchronous_anonymous_pipe_closes_overflow_before_writer_eof(self) -> None:
        assert EXECUTABLE is not None
        executable = Path(EXECUTABLE).resolve()
        for terminated in (False, True):
            with self.subTest(terminated=terminated):
                self._assert_sync_pipe(executable, terminated)

    def _assert_sync_pipe(self, executable: Path, terminated: bool) -> None:
        # Each case owns a distinct closure scope, even if teardown observes a
        # late thread. Its streams and result cells cannot target the next case.
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp)
            child = subprocess.Popen(
                [str(executable), "mcp"],
                env=isolated_environment(profile),
                cwd=profile,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert child.stdin and child.stdout and child.stderr
            first: queue.Queue[bytes] = queue.Queue(maxsize=1)
            outputs: list[bytes] = []
            errors: list[bytes] = []

            def read_stdout() -> None:
                assert child.stdout
                first.put(child.stdout.readline(262145))
                outputs.append(child.stdout.read(262145))

            def read_stderr() -> None:
                assert child.stderr
                errors.append(child.stderr.read(32769))

            readers = [
                threading.Thread(target=read_stdout, daemon=True),
                threading.Thread(target=read_stderr, daemon=True),
            ]
            for reader in readers:
                reader.start()
            writer: threading.Thread | None = None
            write_errors: list[str] = []
            try:
                message = {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {},
                        "clientInfo": {"name": "pipe-smoke", "version": "1"},
                    },
                }
                child.stdin.write((json.dumps(message) + "\n").encode())
                child.stdin.flush()
                initialized = json.loads(first.get(timeout=20))
                self.assertEqual(initialized["id"], 1)
                self.assertNotIn("error", initialized)

                def write_overflow() -> None:
                    assert child.stdin
                    try:
                        child.stdin.write("é".encode() * (131072 + 1))
                        if terminated:
                            child.stdin.write(b"\n")
                        child.stdin.flush()
                    except BrokenPipeError:
                        # Rejection can close the reader before flush returns.
                        write_errors.append("closed")

                writer = threading.Thread(target=write_overflow, daemon=True)
                writer.start()
                self.assertEqual(child.wait(timeout=10), 0)
                writer.join(timeout=3)
                self.assertFalse(writer.is_alive())
                self.assertIn(write_errors, ([], ["closed"]))
                for reader in readers:
                    reader.join(timeout=3)
                    self.assertFalse(reader.is_alive())
                self.assertEqual(outputs, [b""])
                self.assertEqual(len(errors), 1)
                self.assertLessEqual(len(errors[0]), 32768)
                self.assertNotIn("é".encode(), errors[0])
                self.assertIn(
                    errors[0].strip(),
                    (b"", b"quotabot MCP: metadata or transport error"),
                )
                self.assertEqual(list(profile.iterdir()), [])
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
                if writer:
                    writer.join(timeout=3)
                for reader in readers:
                    reader.join(timeout=3)
                # Buffered close takes the stream's lock. A late owner
                # keeps its stream until it returns, rather than turning a
                # bounded join into an unbounded lock wait.
                if writer is None or not writer.is_alive():
                    try:
                        child.stdin.close()
                    except BrokenPipeError:
                        pass
                if not readers[0].is_alive():
                    child.stdout.close()
                if not readers[1].is_alive():
                    child.stderr.close()

    def test_missing_pipe_library_fails_without_starting_an_unowned_reader(
        self,
    ) -> None:
        assert EXECUTABLE is not None
        original = Path(EXECUTABLE).resolve()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            copied = root / "bundle"
            shutil.copytree(original.parent.parent, copied)
            bridge = copied / "lib" / "quotabot_pipe_input.dll"
            self.assertTrue(
                bridge.is_file(), "The complete bundle must include its bridge"
            )
            bridge.unlink()
            profile = root / "profile"
            profile.mkdir()
            child = subprocess.Popen(
                [str(copied / "bin" / original.name), "mcp"],
                env=isolated_environment(profile),
                cwd=profile,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                self.assertNotEqual(child.wait(timeout=10), 0)
                assert child.stdout and child.stderr
                self.assertEqual(child.stdout.read(8193), b"")
                diagnostic = child.stderr.read(8193)
                self.assertLessEqual(len(diagnostic), 8192)
                self.assertIn(b"quotabot_pipe_input", diagnostic)
                self.assertEqual(list(profile.iterdir()), [])
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
                for stream in (child.stdin, child.stdout, child.stderr):
                    if stream:
                        stream.close()
