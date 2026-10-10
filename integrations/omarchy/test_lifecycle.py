"""Collector lifecycle tests. Quotabot is a fake command, and all files are temporary."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


def _load(name: str):
    path = Path(__file__).resolve().parent / "plugin" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"quotabot_omarchy_{name}", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


collect = _load("collect")
ROOT = Path(__file__).resolve().parents[2]
PLUGIN = Path(__file__).resolve().parent / "plugin"


def _snapshot(*, codex_ok: bool = True) -> dict[str, Any]:
    return {
        "schema": "quotabot.v1",
        "generated_at": 1_800_000_000,
        "snapshot_source": "live",
        "providers": [
            {
                "provider": "claude",
                "display_name": "Claude",
                "account": "person@example.com",
                "kind": "subscription",
                "source_class": "authoritative_live",
                "ok": True,
                "stale": False,
                "as_of": 1_800_000_000,
                "windows": [
                    {"label": "week", "used_percent": 20, "resets_at": 1_800_600_000}
                ],
            },
            {
                "provider": "codex",
                "display_name": "Codex",
                "account": "other@example.com",
                "kind": "subscription",
                "source_class": "authoritative_live",
                "ok": codex_ok,
                "error": None if codex_ok else "provider unavailable",
                "stale": False,
                "as_of": 1_800_000_000,
                "windows": []
                if not codex_ok
                else [
                    {"label": "week", "used_percent": 50, "resets_at": 1_800_700_000}
                ],
            },
        ],
    }


def _suggestion() -> dict[str, Any]:
    return {
        "schema": "quotabot.suggest.v1",
        "as_of": 1_800_000_010,
        "decision_code": "balanced_headroom",
        "routing_policy": "balanced",
        "reason": "Use Claude.",
        "recommended": {
            "provider": "claude",
            "account": "person@example.com",
            "headroom_percent": 80,
            "effective_headroom_percent": 80,
            "resets_at": 1_800_600_000,
            "stale": False,
            "available": True,
            "local": False,
        },
        "fallback": {"kind": "local", "provider": "ollama", "reason": "Local runtime."},
        "receipt": {"raw": "person@example.com"},
    }


class LifecycleTests(unittest.TestCase):
    def test_refresh_provider_failure_restart_and_total_cli_failure(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(argv: tuple[str, ...] | list[str], timeout: float):
            del timeout
            arguments = tuple(argv)
            calls.append(arguments)
            if arguments[-1:] == ("--json",) and arguments[-2:-1] != ("suggest",):
                body = _snapshot()
            elif arguments[-2:] == ("suggest", "--json"):
                body = _suggestion()
            else:
                self.fail(f"unexpected command {arguments}")
            return collect.CommandResult(arguments, 0, json.dumps(body), "", False)

        with tempfile.TemporaryDirectory() as raw:
            state = Path(raw) / "state"
            first = collect.refresh(
                state_dir=state,
                executable=("quotabot",),
                runner=runner,
                now=1_800_000_020,
                home=Path("/home/secretuser"),
            )
            self.assertTrue(first.wrote)
            self.assertEqual(
                first.commands,
                (("quotabot", "--json"), ("quotabot", "suggest", "--json")),
            )
            self.assertTrue(first.display["read_ok"])
            loaded = collect.load_display(state)
            self.assertEqual(loaded, first.display)
            self.assertEqual(len(calls), 2)

            def failed_provider(argv, timeout):
                del timeout
                arguments = tuple(argv)
                calls.append(arguments)
                if arguments[-2:] == ("suggest", "--json"):
                    body = _suggestion()
                else:
                    body = _snapshot(codex_ok=False)
                return collect.CommandResult(arguments, 0, json.dumps(body), "", False)

            second = collect.refresh(
                state_dir=state,
                executable=("quotabot",),
                runner=failed_provider,
                now=1_800_000_030,
                home=Path("/home/secretuser"),
            )
            self.assertTrue(second.wrote)
            self.assertTrue(second.display["read_ok"])
            accounts = second.display["accounts"]
            assert isinstance(accounts, list)
            codex = next(item for item in accounts if item["provider"] == "codex")
            claude = next(item for item in accounts if item["provider"] == "claude")
            self.assertEqual(codex["freshness"], "unknown")
            self.assertIsNone(codex["headroom_percent"])
            self.assertEqual(claude["headroom_percent"], 80)
            recommendation = second.display["recommendation"]
            assert isinstance(recommendation, dict)
            self.assertEqual(recommendation["provider"], "claude")
            self.assertNotIn("example.com", json.dumps(second.display))

            before_restart = len(calls)
            restarted = collect.load_display(state)
            self.assertEqual(restarted, second.display)
            self.assertEqual(len(calls), before_restart)

            def broken(argv, timeout):
                del timeout
                arguments = tuple(argv)
                calls.append(arguments)
                return collect.CommandResult(arguments, 1, "", "boom", False)

            third = collect.refresh(
                state_dir=state,
                executable=("quotabot",),
                runner=broken,
                now=1_800_000_040,
                home=Path("/home/secretuser"),
            )
            self.assertFalse(third.display["read_ok"])
            self.assertIn("exited 1", str(third.display["read_error"]))
            self.assertEqual(third.display["accounts"], second.display["accounts"])
            self.assertEqual(
                third.display["recommendation"],
                second.display["recommendation"],
            )
            self.assertFalse((state / collect.LOCK_NAME).exists())

    def test_timeout_preserves_the_previous_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            state = Path(raw) / "state"
            sleeper = Path(raw) / "sleep.py"
            sleeper.write_text("import time\ntime.sleep(30)\n", encoding="utf-8")

            def runner(argv, timeout):
                del timeout
                arguments = tuple(argv)
                body = (
                    _suggestion()
                    if arguments[-2:] == ("suggest", "--json")
                    else _snapshot()
                )
                return collect.CommandResult(arguments, 0, json.dumps(body), "", False)

            collect.refresh(
                state_dir=state,
                executable=("quotabot",),
                runner=runner,
                now=1_800_000_020,
                home=Path("/home/secretuser"),
            )
            result = collect.refresh(
                state_dir=state,
                executable=(sys.executable, str(sleeper)),
                now=1_800_000_050,
                home=Path("/home/secretuser"),
                timeout_seconds=0.2,
            )
            self.assertFalse(result.display["read_ok"])
            self.assertEqual(result.display["read_error"], "quotabot timed out")
            accounts = result.display["accounts"]
            assert isinstance(accounts, list)
            claude = next(item for item in accounts if item["provider"] == "claude")
            self.assertEqual(claude["headroom_percent"], 80)

    def test_concurrent_refresh_does_not_collect(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            state = Path(raw) / "state"
            state.mkdir()
            lock = state / collect.LOCK_NAME
            lock.write_text("held", encoding="utf-8")
            calls: list[tuple[str, ...]] = []

            def runner(argv, timeout):
                del timeout
                calls.append(tuple(argv))
                return collect.CommandResult(tuple(argv), 0, "{}", "", False)

            result = collect.refresh(
                state_dir=state,
                executable=("quotabot",),
                runner=runner,
                now=1_800_000_020,
                home=Path("/home/secretuser"),
            )
            self.assertEqual(calls, [])
            self.assertEqual(result.display["read_error"], "refresh already running")
            self.assertEqual(result.display["accounts"], [])

    def test_uninstall_removes_only_quotabot_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            state = root / "state"
            plugin = root / "plugin"
            agents = root / "agents"
            decoy = root / "other-plugin"
            plugin.mkdir()
            agents.mkdir()
            decoy.mkdir()
            (plugin / "manifest.json").write_text(
                json.dumps({"id": "blisspixel.quotabot"}),
                encoding="utf-8",
            )
            (plugin / "BarWidget.qml").write_text("Item {}", encoding="utf-8")
            (decoy / "manifest.json").write_text(
                json.dumps({"id": "someone.else"}),
                encoding="utf-8",
            )
            (agents / "claude.json").write_text('{"id":"claude"}', encoding="utf-8")
            (agents / "codex.json").write_text('{"id":"codex"}', encoding="utf-8")
            before = {
                name: (agents / name).read_text(encoding="utf-8")
                for name in ("claude.json", "codex.json")
            }
            collect.refresh(
                state_dir=state,
                executable=("quotabot",),
                runner=lambda argv, timeout: collect.CommandResult(
                    tuple(argv),
                    0,
                    json.dumps(
                        _suggestion()
                        if tuple(argv)[-2:] == ("suggest", "--json")
                        else _snapshot()
                    ),
                    "",
                    False,
                ),
                now=1_800_000_020,
                home=Path("/home/secretuser"),
            )
            self.assertTrue((state / collect.DISPLAY_NAME).is_file())
            report = collect.uninstall(
                state_dir=state,
                plugin_dir=plugin,
                agents_dir=agents,
            )
            self.assertFalse((state / collect.DISPLAY_NAME).exists())
            self.assertFalse((state / collect.ALIAS_NAME).exists())
            self.assertFalse(plugin.exists())
            self.assertTrue((decoy / "manifest.json").is_file())
            self.assertEqual(
                report["preserved_agents"],
                ["claude.json", "codex.json"],
            )
            for name, contents in before.items():
                self.assertEqual((agents / name).read_text(encoding="utf-8"), contents)
            skipped = collect.uninstall(
                state_dir=state,
                plugin_dir=decoy,
                agents_dir=agents,
            )
            self.assertIn(
                "plugin manifest is not blisspixel.quotabot",
                skipped["skipped"],
            )
            self.assertTrue(decoy.is_dir())

    def test_refuses_to_replace_a_symlinked_display_file(self) -> None:
        if os.name == "nt":
            self.skipTest("symlink creation is not required on Windows for this guard")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            state = root / "state"
            state.mkdir()
            outside = root / "outside.json"
            outside.write_text("keep", encoding="utf-8")
            link = state / collect.DISPLAY_NAME
            link.symlink_to(outside)
            result = collect.refresh(
                state_dir=state,
                executable=("quotabot",),
                runner=lambda argv, timeout: collect.CommandResult(
                    tuple(argv),
                    0,
                    json.dumps(
                        _suggestion()
                        if tuple(argv)[-2:] == ("suggest", "--json")
                        else _snapshot()
                    ),
                    "",
                    False,
                ),
                now=1_800_000_020,
                home=Path("/home/secretuser"),
            )
            self.assertFalse(result.wrote)
            self.assertEqual(outside.read_text(encoding="utf-8"), "keep")

    def test_source_and_manifest_do_not_target_agent_switching(self) -> None:
        sources = [
            (PLUGIN / name).read_text(encoding="utf-8")
            for name in (
                "BarWidget.qml",
                "Panel.qml",
                "collect.py",
                "display.py",
                "manifest.json",
            )
        ]
        combined = "\n".join(sources)
        for forbidden in (
            "omarchy-agent-account-use",
            "omarchy-agent-account-mode",
            "agents/usage",
            "claude -p",
            "shell=True",
        ):
            self.assertNotIn(forbidden, combined)
        self.assertNotIn(
            "required property", (PLUGIN / "BarWidget.qml").read_text(encoding="utf-8")
        )
        manifest = json.loads((PLUGIN / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "blisspixel.quotabot")
        self.assertFalse(str(manifest["id"]).startswith("omarchy."))
        self.assertEqual(manifest["entryPoints"]["barWidget"], "BarWidget.qml")
        self.assertEqual(manifest["barWidget"]["defaultSection"], "right")
        widget = (PLUGIN / "BarWidget.qml").read_text(encoding="utf-8")
        self.assertIn("import qs.Commons as Commons", widget)
        self.assertIn("property QtObject bar", widget)
        self.assertIn("property string moduleName", widget)
        self.assertIn("property var settings", widget)
        self.assertIn(
            "KeyboardPanel", (PLUGIN / "Panel.qml").read_text(encoding="utf-8")
        )
        self.assertNotIn("\u2014", combined)
        self.assertNotIn("\u2013", combined)

    def test_archive_shape_accepts_plugin_sources_under_lib(self) -> None:
        sys.path.insert(0, str(ROOT / "tools"))
        from verify_cli_archive import verify_cli_archive

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            archive = root / "quotabot-linux-x64.tar.gz"
            _write_sample_archive(archive)
            verified = verify_cli_archive(archive)
            self.assertIn("lib/omarchy/manifest.json", verified.entries)
            self.assertIn("lib/omarchy/collect.py", verified.entries)
            self.assertIn("bin/quotabot", verified.entries)

    def test_packagers_copy_the_plugin_into_lib_omarchy(self) -> None:
        posix = (ROOT / "tools" / "package-cli.sh").read_text(encoding="utf-8")
        windows = (ROOT / "tools" / "package-cli.ps1").read_text(encoding="utf-8")
        self.assertIn("integrations/omarchy/plugin", posix)
        self.assertIn("integrations/omarchy/README.md", posix)
        self.assertIn("integrations\\omarchy\\plugin", windows)
        self.assertIn("integrations\\omarchy\\README.md", windows)

    def test_default_directories_follow_xdg(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            home = {
                "XDG_STATE_HOME": str(Path(raw) / "state"),
                "XDG_CONFIG_HOME": str(Path(raw) / "config"),
            }
            previous = {key: os.environ.get(key) for key in home}
            os.environ.update(home)
            try:
                self.assertEqual(
                    collect.default_state_dir(),
                    Path(raw) / "state" / "quotabot",
                )
                self.assertEqual(
                    collect.default_agents_dir(),
                    Path(raw) / "state" / "omarchy" / "agents" / "usage",
                )
                self.assertEqual(
                    collect.default_plugin_dir().name,
                    "blisspixel.quotabot",
                )
            finally:
                for key, value in previous.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value


def _write_sample_archive(path: Path) -> None:
    import hashlib
    import tarfile

    with tarfile.open(path, "w:gz") as archive:
        _add_bytes(archive, "bin/quotabot", b"#!/bin/sh\n", 0o755)
        _add_bytes(archive, "lib/install.ps1", b"Write-Host ok\n", 0o644)
        _add_bytes(archive, "lib/install.sh", b"#!/bin/sh\n", 0o755)
        manifest = (PLUGIN / "manifest.json").read_bytes()
        collector = (PLUGIN / "collect.py").read_bytes()
        _add_bytes(archive, "lib/omarchy/manifest.json", manifest, 0o644)
        _add_bytes(archive, "lib/omarchy/collect.py", collector, 0o644)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    path.with_suffix(path.suffix + ".sha256").write_text(
        f"{digest}  {path.name}",
        encoding="utf-8",
    )


def _add_bytes(archive: Any, name: str, payload: bytes, mode: int) -> None:
    import io
    import tarfile

    info = tarfile.TarInfo(name)
    info.size = len(payload)
    info.mode = mode
    info.type = tarfile.REGTYPE
    archive.addfile(info, io.BytesIO(payload))


class CliTests(unittest.TestCase):
    def test_refresh_cli_rejects_a_directory_as_quotabot(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(PLUGIN / "collect.py"),
                    "refresh",
                    "--quotabot",
                    raw,
                    "--state-dir",
                    str(Path(raw) / "state"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 2)
            self.assertIn("regular file", completed.stderr)


if __name__ == "__main__":
    unittest.main()
