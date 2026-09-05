from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from render_config import (
    ADVISORY_TOOLS,
    HARNESS_IDS,
    ROOT,
    existing_file,
    main,
    render_config,
)


PACK = Path(__file__).resolve().parent


def server_for(harness: str, config: dict) -> dict:
    if harness == "opencode-1":
        return config["mcp"]["quotabot"]
    if harness == "openclaw":
        return config["mcp"]["servers"]["quotabot"]
    return config["mcp_servers"]["quotabot"]


class HarnessConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory(prefix="quotabot harness ")
        self.addCleanup(self.workspace.cleanup)
        self.directory = Path(self.workspace.name)
        self.collector = self.directory / "source with spaces" / "collector"
        (self.collector / "bin").mkdir(parents=True)
        (self.collector / "bin" / "mcp_server.dart").write_text("", encoding="utf-8")
        (self.collector / "pubspec.yaml").write_text("", encoding="utf-8")
        self.dart = self.directory / "sdk with spaces" / "dart.exe"
        self.dart.parent.mkdir()
        self.dart.write_bytes(b"test file, never executed")

    def test_source_fragments_use_existing_package_working_directory(self) -> None:
        for harness in HARNESS_IDS:
            with self.subTest(harness=harness):
                fragment = render_config(
                    harness, "stdio", collector=self.collector, dart=str(self.dart)
                )
                parsed = json.loads(json.dumps(fragment))
                server = server_for(harness, parsed)
                command = server["command"]
                arguments = server.get("args", [])
                if isinstance(command, list):
                    command, *arguments = command
                self.assertEqual(Path(command), self.dart.resolve())
                self.assertEqual(
                    arguments, ["run", "--verbosity=error", "bin/mcp_server.dart"]
                )
                self.assertEqual(Path(server["cwd"]), self.collector.resolve())
                self.assertTrue((Path(server["cwd"]) / arguments[-1]).is_file())
                self.assertNotIn("shell", server)
                self.assertNotIn("provider", parsed)
                self.assertNotIn("model", parsed)
                self.assertNotIn("agents", parsed)

    def test_compiled_fragments_do_not_require_dart_or_source(self) -> None:
        binary = self.directory / "mcp compiled $ value.exe"
        binary.write_bytes(b"test file, never executed")
        for harness in HARNESS_IDS:
            with self.subTest(harness=harness):
                fragment = render_config(
                    harness,
                    "stdio",
                    executable=str(binary),
                    collector=self.directory / "absent",
                )
                server = server_for(harness, fragment)
                command = server["command"]
                self.assertEqual(
                    command,
                    [str(binary.resolve())]
                    if isinstance(command, list)
                    else str(binary.resolve()),
                )
                self.assertNotIn("cwd", server)
                self.assertNotIn("run", server.get("args", []))

    def test_installed_cli_fragments_append_mcp_without_probing_or_source(self) -> None:
        binary = self.directory / "quotabot $ value.exe"
        binary.write_bytes(b"test file, never executed")
        with (
            patch("subprocess.Popen", side_effect=AssertionError("No version probe")),
            patch(
                "render_config.shutil.which",
                side_effect=AssertionError("No Dart lookup"),
            ),
        ):
            for harness in HARNESS_IDS:
                with self.subTest(harness=harness):
                    config = render_config(
                        harness,
                        "stdio",
                        quotabot=str(binary),
                        collector=self.directory / "absent",
                    )
                    server = server_for(harness, config)
                    command = server["command"]
                    arguments = server.get("args", [])
                    if isinstance(command, list):
                        command, *arguments = command
                    self.assertEqual(command, str(binary.resolve()))
                    self.assertEqual(arguments, ["mcp"])
                    self.assertNotIn("cwd", server)

    def test_quotabot_command_line_option_emits_native_cli_configuration(self) -> None:
        binary = self.directory / "quotabot.exe"
        binary.write_bytes(b"test file, never executed")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(["hermes", "--quotabot", str(binary)]), 0)
        server = server_for("hermes", json.loads(output.getvalue()))
        self.assertEqual(server["command"], str(binary.resolve()))
        self.assertEqual(server["args"], ["mcp"])

    def test_http_fragments_never_read_the_bearer_value(self) -> None:
        sentinel = "a token value that must never appear in a fragment"
        with patch.dict(os.environ, {"QUOTABOT_MCP_TOKEN": sentinel}):
            for harness in HARNESS_IDS:
                with self.subTest(harness=harness):
                    with patch("render_config.existing_file") as stat:
                        config = render_config(harness, "http")
                    stat.assert_not_called()
                    server = server_for(harness, config)
                    self.assertEqual(server["url"], "http://127.0.0.1:8722/mcp")
                    substitution = (
                        "{env:QUOTABOT_MCP_TOKEN}"
                        if harness == "opencode-1"
                        else "${QUOTABOT_MCP_TOKEN}"
                    )
                    self.assertEqual(
                        server["headers"], {"Authorization": "Bearer " + substitution}
                    )
                    serialized = json.dumps(config)
                    self.assertNotIn(sentinel, serialized)
                    self.assertNotIn("command", server)
                    self.assertNotIn("apiKey", serialized)
                    self.assertNotIn("allow_paid_api", serialized)

    def test_opencode_one_shape_disables_lease_tools_and_oauth(self) -> None:
        config = render_config("opencode-1", "http")
        server = server_for("opencode-1", config)
        self.assertNotIn("servers", config["mcp"])
        self.assertEqual(server["type"], "remote")
        self.assertTrue(server["enabled"])
        self.assertFalse(server["oauth"])
        self.assertFalse(config["tools"]["quotabot_reserve_provider"])
        self.assertFalse(config["tools"]["quotabot_release_provider"])

    def test_openclaw_explicitly_selects_streamable_http(self) -> None:
        server = server_for("openclaw", render_config("openclaw", "http"))
        self.assertEqual(server["transport"], "streamable-http")
        self.assertEqual(server["toolFilter"]["include"], list(ADVISORY_TOOLS))
        self.assertNotIn("tools", server)
        self.assertNotIn("auth", server)
        self.assertLessEqual(server["requestTimeoutMs"], 30000)

    def test_hermes_pins_legacy_protocol_and_disables_sampling(self) -> None:
        for transport in ("stdio", "http"):
            arguments = {"dart": str(self.dart), "collector": self.collector}
            if transport == "http":
                arguments = {}
            server = server_for(
                "hermes", render_config("hermes", transport, **arguments)
            )
            self.assertEqual(server["protocol"], "legacy")
            self.assertFalse(server["sampling"]["enabled"])
            self.assertEqual(server["tools"]["include"], list(ADVISORY_TOOLS))
            self.assertFalse(server["tools"]["resources"])
            self.assertFalse(server["tools"]["prompts"])
            self.assertNotIn("transport", server)

    def test_missing_source_package_dart_and_binary_fail_before_output(self) -> None:
        cases = (
            {"collector": self.directory / "absent", "dart": str(self.dart)},
            {"collector": self.collector, "dart": str(self.directory / "absent")},
            {"executable": str(self.directory / "absent")},
            {"quotabot": str(self.directory / "absent")},
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                with self.assertRaises(ValueError):
                    render_config("hermes", "stdio", **arguments)
        (self.collector / "pubspec.yaml").unlink()
        with self.assertRaisesRegex(ValueError, "Collector package"):
            render_config(
                "hermes", "stdio", collector=self.collector, dart=str(self.dart)
            )

    def test_path_lookup_is_explicit_and_does_not_launch_dart(self) -> None:
        with patch("render_config.shutil.which", return_value=str(self.dart)):
            config = render_config("openclaw", "stdio", collector=self.collector)
        self.assertEqual(
            server_for("openclaw", config)["command"], str(self.dart.resolve())
        )
        with patch("render_config.shutil.which", return_value=None):
            with self.assertRaisesRegex(ValueError, "Dart was not found"):
                render_config("openclaw", "stdio", collector=self.collector)

    def test_shell_wrappers_and_ambiguous_modes_are_rejected(self) -> None:
        for suffix in (".bat", ".cmd", ".ps1"):
            wrapper = self.directory / ("dart" + suffix)
            wrapper.write_text("must not execute", encoding="utf-8")
            for option in ("dart", "executable", "quotabot"):
                with self.subTest(suffix=suffix, option=option):
                    with self.assertRaisesRegex(ValueError, "shell wrapper"):
                        render_config(
                            "hermes",
                            "stdio",
                            collector=self.collector,
                            **{option: str(wrapper)},
                        )
        for transport, options in (
            ("http", {"dart": str(self.dart)}),
            ("http", {"executable": str(self.dart)}),
            ("http", {"quotabot": str(self.dart)}),
            ("stdio", {"dart": str(self.dart), "executable": str(self.dart)}),
            ("stdio", {"dart": str(self.dart), "quotabot": str(self.dart)}),
            ("stdio", {"executable": str(self.dart), "quotabot": str(self.dart)}),
        ):
            with self.subTest(transport=transport, options=options):
                with self.assertRaises(ValueError):
                    render_config("hermes", transport, **options)

    def test_unknown_harness_and_transport_fail_closed(self) -> None:
        for harness, transport in (
            ("pi", "http"),
            ("opencode-2", "http"),
            ("hermes", "sse"),
        ):
            with self.subTest(harness=harness, transport=transport):
                with self.assertRaises(ValueError):
                    render_config(harness, transport)

    def test_file_paths_reject_control_characters(self) -> None:
        with patch.object(Path, "is_file", return_value=True):
            with self.assertRaisesRegex(ValueError, "control characters"):
                existing_file(self.directory / "bad\npath", "Test file")

    def test_file_paths_cannot_inject_harness_substitutions(self) -> None:
        for value in ("${QUOTABOT_MCP_TOKEN}", "{env:EXAMPLE}", "{file:EXAMPLE}"):
            with self.subTest(value=value):
                with patch.object(Path, "is_file", return_value=True):
                    with self.assertRaisesRegex(ValueError, "substitution syntax"):
                        existing_file(self.directory / value, "Test file")

    def test_non_ascii_executable_paths_remain_json_data(self) -> None:
        executable = self.directory / "caf\u00e9.exe"
        executable.write_bytes(b"test file, never executed")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(["hermes", "--executable", str(executable)]), 0)
        serialized = output.getvalue()
        self.assertTrue(serialized.isascii())
        self.assertEqual(
            json.loads(serialized)["mcp_servers"]["quotabot"]["command"],
            str(executable.resolve()),
        )

    def test_main_prints_one_json_document_and_no_file(self) -> None:
        before = sorted(self.directory.rglob("*"))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(["openclaw", "--transport", "http"]), 0)
        self.assertIn("quotabot", json.loads(output.getvalue())["mcp"]["servers"])
        self.assertEqual(before, sorted(self.directory.rglob("*")))

    def test_cli_reports_invalid_paths_without_partial_json(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(PACK / "render_config.py"),
                "hermes",
                "--executable",
                str(self.directory / "absent"),
            ],
            cwd=self.directory,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(completed.stdout, "")
        self.assertIn("must name an existing file", completed.stderr)

    def test_main_invalid_mode_returns_an_argument_error(self) -> None:
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            with self.assertRaises(SystemExit) as caught:
                main(["hermes", "--transport", "http", "--dart", str(self.dart)])
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("HTTP configuration does not launch", error.getvalue())

    def test_manifest_distinguishes_documentation_from_harness_smoke(self) -> None:
        manifest = json.loads((PACK / "compatibility.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["mcp_protocol"], "2025-11-25")
        self.assertEqual(manifest["protocol_mode"], "legacy_initialize")
        self.assertEqual(manifest["cli_mcp_minimum_version"], "0.11.0")
        self.assertFalse(manifest["automatic_model_selection"])
        self.assertEqual(manifest["harness_native_smoke"], "not_validated")
        harnesses = {entry["id"]: entry for entry in manifest["harnesses"]}
        for harness in HARNESS_IDS:
            self.assertEqual(harnesses[harness]["support"], "documented_configuration")
            self.assertTrue(harnesses[harness]["sources"])
        self.assertEqual(harnesses["nemoclaw"]["managed_loopback_mcp"], "unsupported")
        self.assertEqual(harnesses["pi"]["transports"], ["cli"])
        self.assertEqual(harnesses["opencode-2"]["support"], "future_untested")

    def test_default_collector_has_the_actual_mcp_entrypoint(self) -> None:
        self.assertTrue((ROOT / "collector" / "bin" / "mcp_server.dart").is_file())
        self.assertTrue((ROOT / "collector" / "pubspec.yaml").is_file())


if __name__ == "__main__":
    unittest.main()
