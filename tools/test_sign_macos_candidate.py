"""Tests for bounded application of the macOS signing plan."""

from __future__ import annotations

import json
import plistlib
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import (
    create_macos_signing_plan,
    native_code_inventory,
    sign_macos_candidate,
)
from tools.sign_macos_candidate import MacOSSigningError


IDENTITY = "Developer ID Application: Example Publisher (ABCDEFGHIJ)"
TEAM_ID = "ABCDEFGHIJ"
CDHASH = "a" * 40


def _macho64() -> bytes:
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)


def _write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def _prepare(base: Path, *, surface: str) -> tuple[Path, Path, Path]:
    root = base / "candidate"
    if surface == "cli":
        _write(root / "bin" / "quotabot", _macho64())
        _write(root / "lib" / "libsqlite3.dylib", _macho64())
    else:
        _write(
            root / "quotabot.app" / "Contents" / "MacOS" / "quotabot",
            _macho64(),
        )
        _write(
            root
            / "quotabot.app"
            / "Contents"
            / "Frameworks"
            / "Example.framework"
            / "Versions"
            / "A"
            / "Example",
            _macho64(),
        )
    inventory = native_code_inventory.inventory_native_code(
        root,
        platform="macos",
        surface=surface,
        architecture="arm64",
    ).to_dict()
    manifest = base / "inventory.json"
    manifest.write_text(json.dumps(inventory), encoding="utf-8")
    plan = base / "plan.json"
    create_macos_signing_plan.create_macos_signing_plan(
        root,
        manifest_path=manifest,
        output_path=plan,
        surface=surface,
        architecture="arm64",
    )
    return root, manifest, plan


class SignMacOSCandidateTests(unittest.TestCase):
    def test_cli_targets_are_signed_in_the_validated_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, plan = _prepare(base, surface="cli")
            codesign = base / "codesign"
            keychain = base / "signing.keychain-db"
            codesign.write_bytes(b"tool")
            keychain.write_bytes(b"keychain")
            receipt = base / "receipt.json"
            commands: list[list[str]] = []

            def runner(command, **_kwargs):
                commands.append(command)
                output = ""
                if "--arch" in command:
                    output = "\n".join(
                        (
                            "CodeDirectory flags=0x10000(runtime)",
                            f"Authority={IDENTITY}",
                            "Timestamp=Aug 30, 2026",
                            f"TeamIdentifier={TEAM_ID}",
                            f"CDHash={CDHASH}",
                        )
                    )
                return subprocess.CompletedProcess(command, 0, output, "")

            result = sign_macos_candidate.apply_macos_signing_plan(
                root,
                manifest_path=manifest,
                plan_path=plan,
                identity=IDENTITY,
                team_id=TEAM_ID,
                keychain_path=keychain,
                entitlements_path=None,
                receipt_path=receipt,
                codesign_path=codesign,
                runner=runner,
            )

            self.assertEqual(result["target_count"], 2)
            self.assertEqual(result["code_directory_count"], 2)
            self.assertEqual(json.loads(receipt.read_text())["ok"], True)
            self.assertTrue(commands[0][-1].replace("\\", "/").endswith("bin/quotabot"))
            self.assertTrue(
                commands[1][-1].replace("\\", "/").endswith("lib/libsqlite3.dylib")
            )
            signing_commands = commands[:2]
            self.assertIn("--identifier", signing_commands[0])
            self.assertIn("io.quotabot.cli", signing_commands[0])
            for command in signing_commands:
                self.assertIn("--options", command)
                self.assertIn("runtime", command)
                self.assertIn("--timestamp", command)
                self.assertNotIn("--entitlements", command)

    def test_desktop_signs_framework_before_outer_app_with_entitlements(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, plan = _prepare(base, surface="desktop")
            codesign = base / "codesign"
            keychain = base / "signing.keychain-db"
            entitlements = base / "Release.entitlements"
            codesign.write_bytes(b"tool")
            keychain.write_bytes(b"keychain")
            expected_entitlements = {"com.example.read-only": True}
            entitlements.write_bytes(plistlib.dumps(expected_entitlements))
            receipt = base / "receipt.json"
            commands: list[list[str]] = []

            def runner(command, **_kwargs):
                commands.append(command)
                output = ""
                if "--entitlements" in command and ":-" in command:
                    if command[-1].endswith("quotabot.app"):
                        output = plistlib.dumps(expected_entitlements).decode("utf-8")
                elif "--arch" in command:
                    output = "\n".join(
                        (
                            "CodeDirectory flags=0x10000(runtime)",
                            f"Authority={IDENTITY}",
                            "Timestamp=Aug 30, 2026",
                            f"TeamIdentifier={TEAM_ID}",
                            f"CDHash={CDHASH}",
                        )
                    )
                return subprocess.CompletedProcess(command, 0, output, "")

            sign_macos_candidate.apply_macos_signing_plan(
                root,
                manifest_path=manifest,
                plan_path=plan,
                identity=IDENTITY,
                team_id=TEAM_ID,
                keychain_path=keychain,
                entitlements_path=entitlements,
                receipt_path=receipt,
                codesign_path=codesign,
                runner=runner,
            )

            signing_commands = commands[:4]
            self.assertTrue(signing_commands[-1][-1].endswith("quotabot.app"))
            self.assertIn("--entitlements", signing_commands[-1])
            app_index = signing_commands[-1].index("--entitlements")
            self.assertEqual(
                signing_commands[-1][app_index + 1], str(entitlements.resolve())
            )
            framework_bundle = next(
                index
                for index, command in enumerate(signing_commands)
                if command[-1].endswith("Example.framework")
            )
            self.assertLess(framework_bundle, len(signing_commands) - 1)

    def test_identity_candidate_and_codesign_failures_are_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, plan = _prepare(base, surface="cli")
            codesign = base / "codesign"
            keychain = base / "signing.keychain-db"
            codesign.write_bytes(b"tool")
            keychain.write_bytes(b"keychain")
            receipt = base / "receipt.json"

            with self.assertRaisesRegex(MacOSSigningError, "identity_invalid"):
                sign_macos_candidate.apply_macos_signing_plan(
                    root,
                    manifest_path=manifest,
                    plan_path=plan,
                    identity="Apple Development: Wrong",
                    team_id=TEAM_ID,
                    keychain_path=keychain,
                    entitlements_path=None,
                    receipt_path=receipt,
                    codesign_path=codesign,
                )

            (root / "bin" / "quotabot").write_bytes(_macho64() + b"changed")
            with self.assertRaisesRegex(
                MacOSSigningError, "candidate_validation_failed"
            ):
                sign_macos_candidate.apply_macos_signing_plan(
                    root,
                    manifest_path=manifest,
                    plan_path=plan,
                    identity=IDENTITY,
                    team_id=TEAM_ID,
                    keychain_path=keychain,
                    entitlements_path=None,
                    receipt_path=receipt,
                    codesign_path=codesign,
                )

            root, manifest, plan = _prepare(base / "fresh", surface="cli")
            fresh_codesign = base / "fresh" / "codesign"
            fresh_keychain = base / "fresh" / "signing.keychain-db"
            fresh_codesign.write_bytes(b"tool")
            fresh_keychain.write_bytes(b"keychain")
            fresh_receipt = base / "fresh" / "receipt.json"

            def failure(command, **_kwargs):
                return subprocess.CompletedProcess(command, 1, "secret", "diagnostic")

            with self.assertRaises(MacOSSigningError) as caught:
                sign_macos_candidate.apply_macos_signing_plan(
                    root,
                    manifest_path=manifest,
                    plan_path=plan,
                    identity=IDENTITY,
                    team_id=TEAM_ID,
                    keychain_path=fresh_keychain,
                    entitlements_path=None,
                    receipt_path=fresh_receipt,
                    codesign_path=fresh_codesign,
                    runner=failure,
                )
            self.assertEqual(caught.exception.code, "codesign_failed")
            self.assertEqual(caught.exception.target, "bin/quotabot")
            self.assertNotIn("secret", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
