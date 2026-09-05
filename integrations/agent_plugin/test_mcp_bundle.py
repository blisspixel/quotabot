"""Opt-in metadata-only smoke of the prepared package and a native CLI bundle."""

from __future__ import annotations

import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator

from prepare_mcp import PATH_FIELDS, ROOT, prepare_mcp


EXECUTABLE = os.environ.get("QUOTABOT_PLUGIN_TEST_EXECUTABLE")
REPLY_LIMIT = 262144


@unittest.skipUnless(
    EXECUTABLE,
    "Set QUOTABOT_PLUGIN_TEST_EXECUTABLE to an existing native quotabot 0.11.0+ CLI",
)
class PreparedPluginBundleTests(unittest.IsolatedAsyncioTestCase):
    async def test_prepared_package_initializes_lists_tools_and_exits_on_eof(
        self,
    ) -> None:
        assert EXECUTABLE is not None
        executable = Path(EXECUTABLE).resolve()
        self.assertTrue(executable.is_file(), "The requested native CLI must exist")
        self.assertIn(executable.name.lower(), {"quotabot", "quotabot.exe"})
        self.assertNotIn(executable.suffix.lower(), {".bat", ".cmd", ".ps1"})
        scratch = Path(tempfile.gettempdir()).resolve()
        with tempfile.TemporaryDirectory(
            prefix="quotabot plugin smoke ", dir=scratch
        ) as tmp:
            temporary = Path(tmp).resolve()
            self.assertTrue(temporary.is_relative_to(scratch))
            profile = temporary / "empty profile"
            plugin_data = temporary / "plugin data"
            profile.mkdir()
            plugin_data.mkdir()
            config = prepare_mcp(**{field: profile for field in PATH_FIELDS})
            schema = json.loads(
                (ROOT / "tests" / "schemas" / "mcp.schema.json").read_text(
                    encoding="utf-8"
                )
            )
            Draft202012Validator(schema).validate(config)
            server = config["mcpServers"]["quotabot"]
            self.assertEqual(server["command"], "quotabot")
            self.assertEqual(server["args"], ["mcp"])
            self.assertEqual(server["cwd"], "${PLUGIN_DATA}")
            environment = {
                name: os.environ[name]
                for name in ("PATH", "SYSTEMROOT", "SystemRoot", "WINDIR", "PATHEXT")
                if name in os.environ
            }
            environment.update(server["env"])
            environment.update(
                PLUGIN_ROOT=str(ROOT),
                PLUGIN_DATA=str(plugin_data),
                XDG_CACHE_HOME=str(profile),
                TEMP=str(plugin_data),
                TMP=str(plugin_data),
            )
            # Resolve the package's bare command to the explicitly supplied bundle.
            # This tests its runtime contract, without an installed client loader.
            process = await asyncio.create_subprocess_exec(
                str(executable),
                *server["args"],
                cwd=plugin_data,
                env=environment,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=REPLY_LIMIT + 1,
            )
            assert process.stdin is not None
            assert process.stdout is not None
            assert process.stderr is not None

            async def diagnostics() -> bytes:
                bounded = bytearray()
                while chunk := await process.stderr.read(4096):
                    bounded.extend(chunk[: max(0, 32769 - len(bounded))])
                return bytes(bounded)

            error_output = asyncio.create_task(diagnostics())

            async def send(message: dict) -> None:
                process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
                await asyncio.wait_for(process.stdin.drain(), timeout=10)

            async def response(identifier: int) -> dict:
                line = await asyncio.wait_for(process.stdout.readline(), timeout=20)
                self.assertTrue(line, "Native MCP process closed before responding")
                self.assertLessEqual(len(line), REPLY_LIMIT)
                payload = json.loads(line)
                self.assertEqual(payload.get("jsonrpc"), "2.0")
                self.assertEqual(payload.get("id"), identifier)
                self.assertNotIn("error", payload)
                return payload["result"]

            try:
                await send(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {
                                "name": "quotabot-plugin-smoke",
                                "version": "1.0.0",
                            },
                        },
                    }
                )
                initialized = await response(1)
                self.assertEqual(initialized["protocolVersion"], "2025-11-25")
                self.assertEqual(initialized["serverInfo"]["name"], "quotabot")
                self.assertIn("tools", initialized["capabilities"])
                await send({"jsonrpc": "2.0", "method": "notifications/initialized"})
                await send(
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
                )
                names = {tool["name"] for tool in (await response(2))["tools"]}
                self.assertTrue(
                    {
                        "suggest_provider",
                        "check_provider_availability",
                        "decide_now",
                        "list_quotas",
                        "list_models",
                        "suggest_model",
                    }.issubset(names)
                )
                process.stdin.close()
                await asyncio.wait_for(process.stdin.wait_closed(), timeout=5)
                self.assertEqual(await asyncio.wait_for(process.wait(), timeout=10), 0)
                self.assertEqual(
                    await asyncio.wait_for(
                        process.stdout.read(REPLY_LIMIT + 1), timeout=5
                    ),
                    b"",
                    "Only requested JSON-RPC responses belong on stdout",
                )
                stderr = await asyncio.wait_for(error_output, timeout=5)
                self.assertLessEqual(len(stderr), 32768)
                self.assertIn(
                    stderr.strip(),
                    (b"", b"[DEBUG][mcp_dart.server.stdio] Stdin closed."),
                    "Only the pinned SDK's ordinary EOF diagnostic is expected",
                )
                self.assertEqual(list(profile.iterdir()), [])
                self.assertEqual(list(plugin_data.iterdir()), [])
            finally:
                if process.returncode is None:
                    process.kill()
                    await asyncio.wait_for(process.wait(), timeout=10)
                process.stdin.close()
                if not error_output.done():
                    error_output.cancel()
                await asyncio.gather(error_output, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
