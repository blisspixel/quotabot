from __future__ import annotations

import json
import math
import py_compile
import unittest
from pathlib import Path
from types import SimpleNamespace

from quotabot_mcp_common import (
    as_pretty_json,
    require_routing_tools,
    routing_summary,
    structured_content,
)


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


class McpClientCommonTest(unittest.TestCase):
    def test_structured_content_prefers_direct_content(self) -> None:
        result = SimpleNamespace(
            structuredContent={"source": "direct"},
            structured_content={"source": "snake"},
            content=[SimpleNamespace(text='{"source":"text"}')],
        )

        self.assertEqual(structured_content(result), {"source": "direct"})

    def test_structured_content_accepts_sdk_variants_and_json_text(self) -> None:
        snake_case = SimpleNamespace(structured_content={"source": "snake"})
        text_content = SimpleNamespace(
            content=[
                SimpleNamespace(binary=b"ignored"),
                SimpleNamespace(text="not json"),
                SimpleNamespace(text='["not", "an", "object"]'),
                SimpleNamespace(text='{"source":"text"}'),
            ]
        )

        self.assertEqual(structured_content(snake_case), {"source": "snake"})
        self.assertEqual(structured_content(text_content), {"source": "text"})
        self.assertEqual(structured_content(SimpleNamespace()), {})

    def test_routing_summary_rejects_invalid_numeric_values(self) -> None:
        for invalid in (True, False, math.nan, math.inf, -math.inf, "75"):
            with self.subTest(value=invalid):
                summary = routing_summary(
                    {"recommended": {"headroom_percent": invalid}}
                )
                self.assertIsNone(summary["headroom_percent"])

        self.assertEqual(
            routing_summary({"recommended": {"headroom_percent": 75}})[
                "headroom_percent"
            ],
            75,
        )

    def test_routing_summary_normalizes_malformed_payloads(self) -> None:
        summary = routing_summary(
            {
                "schema": "quotabot.suggest.v1",
                "recommended": "invalid",
                "fallback": {"provider": "ollama"},
                "using_local_fallback": 1,
            },
            {"schema": "quotabot.models.v1", "recommended": None},
        )

        self.assertEqual(
            summary,
            {
                "suggest_schema": "quotabot.suggest.v1",
                "recommended_provider": None,
                "headroom_percent": None,
                "using_local_fallback": False,
                "fallback_provider": "ollama",
                "model_schema": "quotabot.models.v1",
                "recommended_model": None,
                "model_provider": None,
            },
        )

    def test_require_routing_tools_reports_all_missing_tools(self) -> None:
        with self.assertRaisesRegex(
            RuntimeError,
            "quotabot MCP tools missing: suggest_provider, suggest_model",
        ):
            require_routing_tools([])

        with self.assertRaisesRegex(
            RuntimeError,
            "quotabot MCP tools missing: suggest_model",
        ):
            require_routing_tools(["suggest_provider"])

        require_routing_tools(["suggest_provider", "suggest_model", "other"])

    def test_pretty_json_remains_machine_parseable(self) -> None:
        value = {"schema": "quotabot.suggest.v1", "headroom_percent": 42.5}

        self.assertEqual(json.loads(as_pretty_json(value)), value)

        with self.assertRaises(ValueError):
            as_pretty_json({"headroom_percent": math.nan})


if __name__ == "__main__":
    unittest.main()
