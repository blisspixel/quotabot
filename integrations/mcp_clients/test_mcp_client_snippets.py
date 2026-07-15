from __future__ import annotations

import py_compile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent


class McpClientSnippetTest(unittest.TestCase):
    def test_python_snippets_compile(self) -> None:
        for path in sorted(ROOT.glob("quotabot_mcp_*.py")):
            py_compile.compile(str(path), doraise=True)

    def test_typescript_project_uses_strict_typecheck(self) -> None:
        package_json = (ROOT / "package.json").read_text(encoding="utf-8")
        tsconfig = (ROOT / "tsconfig.json").read_text(encoding="utf-8")

        self.assertIn('"typecheck": "tsc --noEmit"', package_json)
        self.assertIn('"@modelcontextprotocol/sdk": "1.29.0"', package_json)
        self.assertIn('"typescript": "7.0.2"', package_json)
        self.assertIn('"strict": true', tsconfig)

    def test_snippets_use_current_sdk_transports(self) -> None:
        python_http = (ROOT / "quotabot_mcp_http.py").read_text(encoding="utf-8")
        python_stdio = (ROOT / "quotabot_mcp_stdio.py").read_text(encoding="utf-8")
        ts_http = (ROOT / "quotabot_mcp_http.ts").read_text(encoding="utf-8")
        ts_stdio = (ROOT / "quotabot_mcp_stdio.ts").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn(
            "from mcp.client.streamable_http import streamable_http_client",
            python_http,
        )
        self.assertIn("from mcp.client.stdio import stdio_client", python_stdio)
        self.assertIn(
            "@modelcontextprotocol/sdk/client/streamableHttp.js",
            ts_http,
        )
        self.assertIn("@modelcontextprotocol/sdk/client/stdio.js", ts_stdio)
        self.assertIn("requestInit", ts_http)
        self.assertIn('"mcp>=1.28,<2"', readme)

    def test_snippets_stay_fail_soft_and_metadata_only(self) -> None:
        joined = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(ROOT.glob("quotabot_mcp_*.*"))
        )
        self.assertIn("quotabot MCP unavailable", joined)
        self.assertIn("suggest_provider", joined)
        self.assertIn("suggest_model", joined)
        self.assertNotIn("TO" + "DO", joined)
        self.assertNotIn("place" + "holder", joined.lower())
        self.assertNotIn("\n" + "pa" + "ss\n", joined)


if __name__ == "__main__":
    unittest.main()
