"""Credential-free integration tests against the installed Apple codesign tools."""

from __future__ import annotations

import json
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools import (
    create_macos_signing_plan,
    native_code_inventory,
    validate_macos_signing_delta,
)
from tools.macos_codesign_output import code_directory_details, embedded_entitlements
from tools.sign_macos_candidate import CLI_IDENTIFIER


ROOT = Path(__file__).resolve().parents[1]
CDHASH = re.compile(r"^[0-9a-f]{40}$")


@unittest.skipUnless(
    sys.platform == "darwin" and platform.machine() == "arm64",
    "native codesign integration requires arm64 macOS",
)
class MacOSCodeSignIntegrationTests(unittest.TestCase):
    def _run(self, command: list[str]) -> str:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=180,
        )
        output = f"{completed.stdout}\n{completed.stderr}"
        self.assertEqual(completed.returncode, 0, output[-4000:])
        self.assertLessEqual(len(output), 256 * 1024)
        return output

    def _compile(self, source: Path, output: Path, *, dylib: bool = False) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        command = [
            "/usr/bin/xcrun",
            "clang",
            "-arch",
            "arm64",
            "-mmacosx-version-min=13.0",
        ]
        if dylib:
            command.extend(("-dynamiclib", "-Wl,-install_name,@rpath/libfixture.dylib"))
        command.extend((str(source), "-o", str(output)))
        self._run(command)

    def _candidate(self, base: Path, *, surface: str) -> Path:
        base.mkdir(parents=True, exist_ok=True)
        root = base / f"{surface}-candidate"
        executable_source = base / "main.c"
        executable_source.write_text("int main(void) { return 0; }\n", encoding="ascii")
        library_source = base / "library.c"
        library_source.write_text("int fixture(void) { return 1; }\n", encoding="ascii")
        if surface == "cli":
            self._compile(executable_source, root / "bin" / "quotabot")
            self._compile(library_source, root / "lib" / "libfixture.dylib", dylib=True)
            return root

        app = root / "quotabot.app"
        self._compile(executable_source, app / "Contents" / "MacOS" / "quotabot")
        self._compile(
            library_source,
            app / "Contents" / "Frameworks" / "libfixture.dylib",
            dylib=True,
        )
        (app / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": "quotabot",
                    "CFBundleIdentifier": "io.quotabot.integration",
                    "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                }
            )
        )
        return root

    def _exercise(self, base: Path, *, surface: str) -> None:
        unsigned = self._candidate(base, surface=surface)
        manifest_value = native_code_inventory.inventory_native_code(
            unsigned,
            platform="macos",
            surface=surface,
            architecture="arm64",
        ).to_dict()
        manifest = base / f"{surface}-unsigned-inventory.json"
        manifest.write_text(json.dumps(manifest_value), encoding="ascii")
        plan_path = base / f"{surface}-signing-plan.json"
        plan = create_macos_signing_plan.create_macos_signing_plan(
            unsigned,
            manifest_path=manifest,
            output_path=plan_path,
            surface=surface,
            architecture="arm64",
        )
        signed = base / f"{surface}-signed"
        self._run(["/usr/bin/ditto", str(unsigned), str(signed)])

        processed: list[str] = []
        targets = plan["targets"]
        self.assertIsInstance(targets, list)
        for target in targets:
            self.assertIsInstance(target, dict)
            relative = str(target["path"])
            processed.append(relative)
            command = [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--options",
                "runtime",
                "--timestamp=none",
            ]
            if surface == "cli" and relative == "bin/quotabot":
                command.extend(("--identifier", CLI_IDENTIFIER))
            if target.get("entitlements") == "app_release":
                command.extend(
                    (
                        "--entitlements",
                        str(
                            ROOT
                            / "app"
                            / "macos"
                            / "Runner"
                            / "DeveloperID.entitlements"
                        ),
                    )
                )
            target_path = signed / relative
            command.append(str(target_path))
            self._run(command)

        self.assertEqual(processed, [str(target["path"]) for target in targets])
        if surface == "desktop":
            self.assertEqual(processed[-1], "quotabot.app")

        native_architectures = {
            str(entry["path"]): str(entry["architecture"]).split("+")
            for entry in manifest_value["native_code"]
            if isinstance(entry, dict)
        }
        for target in targets:
            self.assertIsInstance(target, dict)
            relative = str(target["path"])
            target_path = signed / relative
            verify = ["/usr/bin/codesign", "--verify", "--strict", "--verbose=4"]
            if target.get("kind") == "bundle":
                verify.append("--deep")
            verify.append(str(target_path))
            self._run(verify)
            entitlement_output = self._run(
                [
                    "/usr/bin/codesign",
                    "--display",
                    "--entitlements",
                    ":-",
                    str(target_path),
                ]
            )
            self.assertEqual(embedded_entitlements(entitlement_output), {})
            if target.get("kind") != "macho":
                continue
            self.assertEqual(native_architectures[relative], ["arm64"])
            details = self._run(
                [
                    "/usr/bin/codesign",
                    "--display",
                    "--verbose=4",
                    "--arch",
                    "arm64",
                    str(target_path),
                ]
            )
            self.assertIn("Signature=adhoc", details)
            cdhash = code_directory_details(
                details,
                identity=None,
                team_id=None,
                expected_identifier=(
                    CLI_IDENTIFIER
                    if surface == "cli" and relative == "bin/quotabot"
                    else None
                ),
                require_timestamp=False,
            )
            self.assertIsNotNone(cdhash)
            self.assertIsNotNone(CDHASH.fullmatch(str(cdhash)))

        signed_inventory = native_code_inventory.inventory_native_code(
            signed,
            platform="macos",
            surface=surface,
            architecture="arm64",
        ).to_dict()
        after = base / f"{surface}-signed-inventory.json"
        after.write_text(json.dumps(signed_inventory), encoding="ascii")
        receipt = validate_macos_signing_delta.validate_macos_signing_delta(
            manifest,
            after,
            plan_path,
            operation="signing",
        )
        self.assertEqual(receipt["changed_native_count"], len(native_architectures))

    def test_real_apple_tools_sign_and_parse_cli_and_desktop_candidates(self) -> None:
        self.assertIsNotNone(shutil.which("xcrun"))
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            self._exercise(base / "cli", surface="cli")
            self._exercise(base / "desktop", surface="desktop")


if __name__ == "__main__":
    unittest.main()
