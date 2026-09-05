from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml
from jsonschema import Draft202012Validator

import prepare_mcp


ROOT = Path(__file__).resolve().parent
SCHEMAS = ROOT / "tests" / "schemas"


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class AgentPluginTests(unittest.TestCase):
    def test_canonical_schemas_validate_both_components_offline(self) -> None:
        with patch("socket.socket", side_effect=AssertionError("Network forbidden")):
            for component in ("plugin", "mcp"):
                with self.subTest(component=component):
                    schema = read_json(SCHEMAS / f"{component}.schema.json")
                    Draft202012Validator.check_schema(schema)
                    Draft202012Validator(schema).validate(
                        read_json(ROOT / f"{component}.json")
                    )

    def test_vendored_schema_contents_remain_the_reviewed_version(self) -> None:
        expected = {
            "plugin.schema.json": (
                "0a4aad95ce337878ad38802ebf0daa3fde76abe3f65400c86bcbb1ec0b3ab883"
            ),
            "mcp.schema.json": (
                "6539175bfcdf43085855183e86da40ea94b166547a72b47ae9a0a390516d3acb"
            ),
        }
        for name, digest in expected.items():
            self.assertEqual(
                hashlib.sha256((SCHEMAS / name).read_bytes()).hexdigest(), digest
            )

    def test_package_discovery_paths_are_real_and_contained(self) -> None:
        self.assertTrue((ROOT / "plugin.json").is_file())
        self.assertTrue((ROOT / "mcp.json").is_file())
        self.assertTrue((ROOT / "skills").is_dir())
        skills = list((ROOT / "skills").glob("*/SKILL.md"))
        self.assertEqual(len(skills), 1)
        for path in (ROOT / "plugin.json", ROOT / "mcp.json", *skills):
            self.assertTrue(path.resolve().is_relative_to(ROOT))
            self.assertTrue(path.is_file())
        for path in ROOT.rglob("*"):
            self.assertTrue(path.resolve().is_relative_to(ROOT), str(path))

    def test_advisory_skill_uses_portable_frontmatter_and_discovery(self) -> None:
        skill = ROOT / "skills" / "quota-advice" / "SKILL.md"
        sections = skill.read_text(encoding="utf-8").split("---", 2)
        self.assertEqual(sections[0], "")
        frontmatter = yaml.safe_load(sections[1])
        self.assertEqual(frontmatter["name"], skill.parent.name)
        self.assertRegex(frontmatter["name"], r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
        self.assertLessEqual(len(frontmatter["name"]), 64)
        self.assertIsInstance(frontmatter["description"], str)
        self.assertTrue(1 <= len(frontmatter["description"]) <= 1024)
        self.assertEqual(set(frontmatter), {"name", "description"})
        self.assertTrue(sections[2].strip())
        self.assertNotIn("allowed-tools", frontmatter)

    def test_native_launch_needs_no_shell_download_or_secret(self) -> None:
        config = read_json(ROOT / "mcp.json")
        self.assertEqual(set(config["mcpServers"]), {"quotabot"})
        server = config["mcpServers"]["quotabot"]
        self.assertEqual(
            server,
            {
                "type": "stdio",
                "command": "quotabot",
                "args": ["mcp"],
                "cwd": "${PLUGIN_DATA}",
            },
        )
        self.assertIsNone(re.search(r"[/\\\s$]", server["command"]))
        self.assertFalse(read_json(ROOT / "plugin.json").get("extensions"))

    def test_generated_paths_validate_against_the_actual_mcp_schema(self) -> None:
        with tempfile.TemporaryDirectory(prefix="quotabot profile ") as directory:
            profile = Path(directory)
            values = {
                field: profile for field in prepare_mcp.PATH_FIELDS if field != "home"
            }
            config = prepare_mcp.prepare_mcp(home=profile, **values)
            Draft202012Validator(read_json(SCHEMAS / "mcp.schema.json")).validate(
                config
            )
            env = config["mcpServers"]["quotabot"]["env"]
            self.assertEqual(
                set(env),
                {
                    "HOME",
                    "USERPROFILE",
                    "APPDATA",
                    "LOCALAPPDATA",
                    "XDG_CONFIG_HOME",
                    "XDG_DATA_HOME",
                },
            )
            self.assertEqual(set(env.values()), {str(profile.resolve())})

    def test_preparation_reads_no_environment_or_credentials_and_launches_nothing(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(
                    os.environ,
                    "get",
                    side_effect=AssertionError("No environment reads"),
                ),
                patch(
                    "subprocess.Popen", side_effect=AssertionError("No process launch")
                ),
                patch("socket.socket", side_effect=AssertionError("No network")),
            ):
                config = prepare_mcp.prepare_mcp(home=directory)
            self.assertEqual(
                set(config["mcpServers"]["quotabot"]["env"]), {"HOME", "USERPROFILE"}
            )

    def test_profile_paths_stay_json_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "profile $dollar [brackets] \u00e9"
            profile.mkdir()
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(prepare_mcp.main(["--home", str(profile)]), 0)
            serialized = output.getvalue()
            serialized.encode("ascii")
            result = json.loads(serialized)
            self.assertEqual(
                result["mcpServers"]["quotabot"]["env"]["HOME"], str(profile.resolve())
            )
            self.assertEqual(result["mcpServers"]["quotabot"]["args"], ["mcp"])

    def test_unknown_environment_fields_cannot_smuggle_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "nonsecret directory"):
                prepare_mcp.prepare_mcp(home=directory, api_token="token-sentinel")

    def test_relative_missing_and_non_directory_paths_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "absolute"):
            prepare_mcp.directory_value("relative/profile")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "ordinary-file"
            file.write_text("bounded fixture", encoding="utf-8")
            for path in (root / "missing", file):
                with self.subTest(path=path.name):
                    with self.assertRaisesRegex(ValueError, "existing directories"):
                        prepare_mcp.directory_value(path)

    def test_plugin_placeholders_and_controls_are_rejected_in_personal_paths(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for tail in ("${PLUGIN_ROOT}", "${PLUGIN_DATA}", "${HOME}", "bad\nname"):
                with self.subTest(tail=tail):
                    with self.assertRaises(ValueError):
                        prepare_mcp.directory_value(Path(directory) / tail)

    def test_preparation_never_rewrites_the_package_or_profile(self) -> None:
        before = (ROOT / "mcp.json").read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "host-config"
            marker.write_text("unchanged", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                prepare_mcp.main(["--home", str(root)])
            self.assertEqual(list(root.iterdir()), [marker])
            self.assertEqual(marker.read_text(encoding="utf-8"), "unchanged")
        self.assertEqual((ROOT / "mcp.json").read_bytes(), before)

    def test_preparation_rejects_an_escaping_template_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            package.mkdir()
            outside = root / "outside.json"
            outside.write_text("{}", encoding="utf-8")
            try:
                (package / "mcp.json").symlink_to(outside)
            except OSError as error:
                self.skipTest(f"Symlink creation is unavailable: {error.strerror}")
            with patch.object(prepare_mcp, "ROOT", package.resolve()):
                with self.assertRaisesRegex(ValueError, "inside the plugin"):
                    prepare_mcp.prepare_mcp(home=root)

    def test_invalid_command_line_emits_no_partial_configuration(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                with self.assertRaises(SystemExit) as raised:
                    prepare_mcp.main(["--home", "relative/path"])
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("absolute", stderr.getvalue())

    def test_script_prints_one_document_without_host_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(ROOT / "prepare_mcp.py"), "--home", directory],
                cwd=directory,
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.stderr, "")
            self.assertEqual(
                json.loads(result.stdout)["mcpServers"]["quotabot"]["command"],
                "quotabot",
            )
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
