"""Tests for the exact macOS native-code signing plan."""

from __future__ import annotations

import json
import os
import struct
import tempfile
import unittest
from pathlib import Path

from tools import create_macos_signing_plan, native_code_inventory
from tools.create_macos_signing_plan import MacOSSigningPlanError


def _macho64(*, cpu_type: int = 0x0100000C) -> bytes:
    return struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        cpu_type,
        0,
        2,
        0,
        0,
        0,
        0,
    )


def _write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def _inventory(root: Path, surface: str) -> dict[str, object]:
    return native_code_inventory.inventory_native_code(
        root,
        platform="macos",
        surface=surface,
        architecture="arm64",
    ).to_dict()


def _write_manifest(path: Path, inventory: dict[str, object]) -> None:
    path.write_text(json.dumps(inventory), encoding="utf-8")


class MacOSSigningPlanTests(unittest.TestCase):
    def test_cli_plan_signs_each_macho_without_bundle_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "candidate"
            _write(root / "bin" / "quotabot", _macho64())
            _write(root / "lib" / "libsqlite3.dylib", _macho64())
            inventory = _inventory(root, "cli")
            manifest = base / "inventory.json"
            output = base / "plan.json"
            _write_manifest(manifest, inventory)

            plan = create_macos_signing_plan.create_macos_signing_plan(
                root,
                manifest_path=manifest,
                output_path=output,
                surface="cli",
                architecture="arm64",
            )

            self.assertEqual(plan["target_count"], 2)
            self.assertEqual(
                plan["targets"],
                [
                    {
                        "path": "bin/quotabot",
                        "kind": "macho",
                        "entitlements": None,
                    },
                    {
                        "path": "lib/libsqlite3.dylib",
                        "kind": "macho",
                        "entitlements": None,
                    },
                ],
            )
            self.assertEqual(
                create_macos_signing_plan.load_macos_signing_plan(output), plan
            )

    def test_desktop_plan_is_inside_out_and_outer_app_receives_entitlements(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "candidate"
            _write(
                root / "quotabot.app" / "Contents" / "MacOS" / "quotabot",
                _macho64(),
            )
            framework = (
                root / "quotabot.app" / "Contents" / "Frameworks" / "Example.framework"
            )
            _write(framework / "Versions" / "A" / "Example", _macho64())
            inventory = _inventory(root, "desktop")
            manifest = base / "inventory.json"
            output = base / "plan.json"
            _write_manifest(manifest, inventory)

            plan = create_macos_signing_plan.create_macos_signing_plan(
                root,
                manifest_path=manifest,
                output_path=output,
                surface="desktop",
                architecture="arm64",
            )

            targets = plan["targets"]
            self.assertEqual(targets[-1]["path"], "quotabot.app")
            self.assertEqual(targets[-1]["entitlements"], "app_release")
            framework_index = next(
                index
                for index, target in enumerate(targets)
                if target["path"].endswith("Example.framework")
            )
            framework_binary_index = next(
                index
                for index, target in enumerate(targets)
                if target["path"].endswith("Versions/A/Example")
            )
            self.assertLess(framework_binary_index, framework_index)
            self.assertLess(framework_index, len(targets) - 1)

    def test_candidate_change_and_plan_tamper_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "candidate"
            launcher = root / "bin" / "quotabot"
            _write(launcher, _macho64())
            inventory = _inventory(root, "cli")
            manifest = base / "inventory.json"
            output = base / "plan.json"
            _write_manifest(manifest, inventory)
            launcher.write_bytes(_macho64() + b"changed")

            with self.assertRaisesRegex(MacOSSigningPlanError, "complete inventory"):
                create_macos_signing_plan.create_macos_signing_plan(
                    root,
                    manifest_path=manifest,
                    output_path=output,
                    surface="cli",
                    architecture="arm64",
                )

            _write(launcher, _macho64())
            create_macos_signing_plan.create_macos_signing_plan(
                root,
                manifest_path=manifest,
                output_path=output,
                surface="cli",
                architecture="arm64",
            )
            value = json.loads(output.read_text(encoding="ascii"))
            value["targets"][0]["path"] = "../outside"
            output.write_text(json.dumps(value), encoding="ascii")
            with self.assertRaisesRegex(MacOSSigningPlanError, "invalid"):
                create_macos_signing_plan.load_macos_signing_plan(output)

    @unittest.skipIf(os.name == "nt", "symlink creation is not portable on Windows")
    def test_plan_output_link_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "candidate"
            _write(root / "bin" / "quotabot", _macho64())
            manifest = base / "inventory.json"
            _write_manifest(manifest, _inventory(root, "cli"))
            target = base / "outside.json"
            target.write_text("outside", encoding="utf-8")
            output = base / "plan.json"
            output.symlink_to(target)

            with self.assertRaisesRegex(MacOSSigningPlanError, "output path"):
                create_macos_signing_plan.create_macos_signing_plan(
                    root,
                    manifest_path=manifest,
                    output_path=output,
                    surface="cli",
                    architecture="arm64",
                )


if __name__ == "__main__":
    unittest.main()
