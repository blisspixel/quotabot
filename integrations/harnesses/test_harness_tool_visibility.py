"""Source-derived catalog contracts, not execution of an installed harness."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from render_config import render_config


PACK = Path(__file__).resolve().parent
CONTRACT = json.loads(
    (PACK / "fixtures" / "tool_visibility.json").read_text(encoding="utf-8")
)
EXPECTED_ADVICE = set(CONTRACT["expected_advisory_tools"])


def source_derived_visible_tools(
    harness: str, config: dict, native_tools: set[str], capabilities: dict
) -> set[str]:
    """Project exact-name recipes using independently pinned upstream behavior.

    This bounded fixture covers the renderer's exact include lists and boolean
    utility toggles. It does not implement client loading, glob filters, schema
    conversion, execution, or authentication.
    """
    rules = CONTRACT["clients"][harness]
    server = config
    for key in rules["server_path"]:
        server = server[key]
    policy = server.get(rules["filter_key"], {})
    include = policy.get("include")

    def selected(names: set[str]) -> set[str]:
        if include is None or (not include and rules["empty_include_means_all"]):
            return set(names)
        return names.intersection(include)

    visible = selected(native_tools)
    for family, utility_names in rules["utility_tools"].items():
        if family not in capabilities:
            continue
        if rules["utilities_share_filter"]:
            visible.update(selected(set(utility_names)))
        elif policy.get(family, True):
            visible.update(utility_names)
    return visible


class HarnessToolVisibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory(prefix="quotabot catalog ")
        self.addCleanup(self.workspace.cleanup)
        self.binary = Path(self.workspace.name) / "quotabot.exe"
        self.binary.write_bytes(b"synthetic file, never executed")

    def test_rendered_recipes_expose_exact_advice_even_with_utility_capabilities(
        self,
    ) -> None:
        # Prompts and an extra tool are synthetic future catalog entries. Neither
        # may widen the recipe's advertised six-tool advisory surface.
        native = set(CONTRACT["native_tools"]) | {"synthetic_future_tool"}
        capabilities = {"tools": {}, "resources": {}, "prompts": {}}
        for harness in CONTRACT["clients"]:
            for transport in ("stdio", "http"):
                with self.subTest(harness=harness, transport=transport):
                    options = (
                        {"quotabot": str(self.binary)} if transport == "stdio" else {}
                    )
                    config = json.loads(
                        json.dumps(render_config(harness, transport, **options))
                    )
                    self.assertEqual(
                        source_derived_visible_tools(
                            harness, config, native, capabilities
                        ),
                        EXPECTED_ADVICE,
                    )

    def test_openclaw_ignored_tools_key_leaks_leases_and_resource_utilities(
        self,
    ) -> None:
        wrong = {
            "mcp": {
                "servers": {"quotabot": {"tools": {"include": sorted(EXPECTED_ADVICE)}}}
            }
        }
        visible = source_derived_visible_tools(
            "openclaw", wrong, set(CONTRACT["native_tools"]), {"resources": {}}
        )
        self.assertEqual(
            visible,
            set(CONTRACT["native_tools"]) | {"resources_list", "resources_read"},
        )
        self.assertNotEqual(visible, EXPECTED_ADVICE)

    def test_hermes_include_does_not_disable_default_utility_wrappers(self) -> None:
        config = {
            "mcp_servers": {"quotabot": {"tools": {"include": sorted(EXPECTED_ADVICE)}}}
        }
        for family, wrappers in CONTRACT["clients"]["hermes"]["utility_tools"].items():
            with self.subTest(family=family):
                self.assertEqual(
                    source_derived_visible_tools(
                        "hermes", config, set(CONTRACT["native_tools"]), {family: {}}
                    ),
                    EXPECTED_ADVICE | set(wrappers),
                )

    def test_utility_wrappers_require_advertised_capabilities(self) -> None:
        for harness, config in (
            ("openclaw", {"mcp": {"servers": {"quotabot": {}}}}),
            ("hermes", {"mcp_servers": {"quotabot": {}}}),
        ):
            with self.subTest(harness=harness):
                native = set(CONTRACT["native_tools"])
                self.assertEqual(
                    source_derived_visible_tools(harness, config, native, {}), native
                )

    def test_fixture_pins_reviewed_client_versions_and_primary_commits(self) -> None:
        manifest = json.loads((PACK / "compatibility.json").read_text(encoding="utf-8"))
        clients = {entry["id"]: entry for entry in manifest["harnesses"]}
        self.assertEqual(CONTRACT["evidence"], "source_derived_exact_name_contract")
        for harness, rules in CONTRACT["clients"].items():
            with self.subTest(harness=harness):
                self.assertEqual(rules["version"], clients[harness]["version_reviewed"])
                self.assertEqual(rules["commit"], clients[harness]["source_commit"])
                self.assertRegex(rules["commit"], r"^[0-9a-f]{40}$")
                self.assertTrue(rules["sources"])
                for source in rules["sources"]:
                    self.assertIn(f"/blob/{rules['commit']}/", source)


if __name__ == "__main__":
    unittest.main()
