from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from render_config import ROOT, render_config
from test_harness_tool_visibility import EXPECTED_ADVICE, source_derived_visible_tools


def native_dart() -> str | None:
    selected = os.environ.get("QUOTABOT_HARNESS_TEST_DART") or shutil.which("dart")
    if not selected:
        return None
    path = Path(selected).resolve()
    if path.suffix.lower() in {".bat", ".cmd"}:
        for candidate in (
            path.with_suffix(".exe"),
            path.parent / "cache" / "dart-sdk" / "bin" / "dart.exe",
        ):
            if candidate.is_file():
                return str(candidate)
    return str(path)


SMOKE_REQUESTED = os.environ.get("QUOTABOT_HARNESS_SMOKE") == "1" or bool(
    os.environ.get("QUOTABOT_HARNESS_TEST_DART")
)
DART = native_dart() if SMOKE_REQUESTED else None


@unittest.skipUnless(
    SMOKE_REQUESTED, "Set QUOTABOT_HARNESS_SMOKE=1 to run the MCP entrypoint smoke"
)
class McpEntrypointTests(unittest.TestCase):
    def test_rendered_source_command_initializes_and_lists_tools_without_collection(
        self,
    ) -> None:
        self.assertIsNotNone(
            DART, "A native Dart executable is required for the requested smoke"
        )
        config = render_config("openclaw", "stdio", dart=DART)
        server = config["mcp"]["servers"]["quotabot"]
        self.assertEqual(Path(server["cwd"]), ROOT / "collector")
        with tempfile.TemporaryDirectory(prefix="quotabot mcp smoke ") as temporary:
            env = {
                name: os.environ[name]
                for name in ("PATH", "SYSTEMROOT", "SystemRoot", "WINDIR", "PATHEXT")
                if name in os.environ
            }
            for name in (
                "HOME",
                "USERPROFILE",
                "APPDATA",
                "LOCALAPPDATA",
                "XDG_CONFIG_HOME",
                "XDG_CACHE_HOME",
                "TEMP",
                "TMP",
            ):
                env[name] = temporary
            process = subprocess.Popen(
                [server["command"], *server["args"]],
                cwd=server["cwd"],
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            output: queue.Queue[bytes | None] = queue.Queue(maxsize=8)
            error_tail = bytearray()

            def collect_stderr() -> None:
                assert process.stderr is not None
                while chunk := process.stderr.read(4096):
                    error_tail.extend(chunk)
                    del error_tail[:-32768]

            def collect_lines() -> None:
                assert process.stdout is not None
                while True:
                    line = process.stdout.readline(262145)
                    if not line:
                        output.put(None)
                        return
                    output.put(line)
                    if len(line) > 262144:
                        return

            reader = threading.Thread(target=collect_lines, daemon=True)
            error_reader = threading.Thread(target=collect_stderr, daemon=True)
            reader.start()
            error_reader.start()
            deadline = time.monotonic() + 45

            def send(value: dict) -> None:
                assert process.stdin is not None
                process.stdin.write((json.dumps(value) + "\n").encode("utf-8"))
                process.stdin.flush()

            def response(identifier: int) -> dict:
                line = output.get(timeout=max(0.1, deadline - time.monotonic()))
                if line is None:
                    error_reader.join(timeout=1)
                self.assertIsNotNone(
                    line,
                    "MCP process closed before responding: "
                    + error_tail.decode("utf-8", errors="replace"),
                )
                assert line is not None
                self.assertLessEqual(
                    len(line), 262144, "MCP reply exceeded smoke bound"
                )
                payload = json.loads(line)
                self.assertEqual(payload.get("id"), identifier)
                self.assertNotIn("error", payload)
                return payload["result"]

            try:
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {
                                "name": "quotabot-harness-smoke",
                                "version": "1.0.0",
                            },
                        },
                    }
                )
                initialized = response(1)
                self.assertEqual(initialized["protocolVersion"], "2025-11-25")
                self.assertIn("tools", initialized["capabilities"])
                send({"jsonrpc": "2.0", "method": "notifications/initialized"})
                send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
                tools = response(2)["tools"]
                names = {tool["name"] for tool in tools}
                self.assertTrue(EXPECTED_ADVICE.issubset(names))
                self.assertIn("reserve_provider", names)
                self.assertIn("release_provider", names)
                # Apply the independent pinned contract to this real server
                # catalog. This is still not execution of either harness.
                for harness in ("openclaw", "hermes"):
                    with self.subTest(harness=harness):
                        fragment = render_config(harness, "stdio", dart=DART)
                        self.assertEqual(
                            source_derived_visible_tools(
                                harness,
                                fragment,
                                names,
                                initialized["capabilities"],
                            ),
                            EXPECTED_ADVICE,
                        )
                assert process.stdin is not None
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
                if process.stdin is not None and not process.stdin.closed:
                    process.stdin.close()
                reader.join(timeout=5)
                error_reader.join(timeout=5)
                if process.stdout is not None:
                    process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()


if __name__ == "__main__":
    unittest.main()
