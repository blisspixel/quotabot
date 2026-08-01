"""Tests for the bounded Windows PE signing payload inventory."""

from __future__ import annotations

import io
import json
import os
import shutil
import struct
import tempfile
import unittest
import unittest.mock as mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tools import native_code_inventory
from tools.native_code_inventory import NativeInventoryError, inventory_native_code


def _pe(*, machine: int = 0x8664) -> bytes:
    payload = bytearray(512)
    payload[0:2] = b"MZ"
    struct.pack_into("<I", payload, 0x3C, 0x80)
    payload[0x80:0x84] = b"PE\x00\x00"
    struct.pack_into("<HHIIIHH", payload, 0x84, machine, 1, 0, 0, 0, 0xF0, 0x2022)
    struct.pack_into("<H", payload, 0x98, 0x20B)
    struct.pack_into("<II", payload, 0xD0, 4096, 512)
    return bytes(payload)


def _write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def _inventory(root: Path, *, surface: str = "cli"):
    return inventory_native_code(
        root,
        platform="windows",
        surface=surface,
        architecture="x64",
    )


class NativeCodeInventoryTests(unittest.TestCase):
    def test_cli_inventory_discovers_every_pe_by_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "bin" / "quotabot.exe", _pe())
            _write(root / "lib" / "sqlite3.dll", _pe())
            _write(root / "lib" / "plugin.bin", _pe())
            _write(root / "lib" / "notice.txt", b"not native code\n")

            result = _inventory(root)

            self.assertEqual(result.schema, "quotabot.signing-inventory.v1")
            self.assertEqual(result.platform, "windows")
            self.assertEqual(result.surface, "cli")
            self.assertEqual(result.architecture, "x64")
            self.assertEqual(result.candidate_file_count, 4)
            self.assertEqual(
                [entry.path for entry in result.native_code],
                ["bin/quotabot.exe", "lib/plugin.bin", "lib/sqlite3.dll"],
            )
            self.assertEqual(
                {entry.architecture for entry in result.native_code}, {"x64"}
            )
            self.assertRegex(result.candidate_sha256, r"^[0-9a-f]{64}$")
            self.assertRegex(result.inventory_sha256, r"^[0-9a-f]{64}$")

    def test_desktop_requires_a_valid_primary_pe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "quotabot.exe", b"not a portable executable")
            _write(root / "plugin.dll", _pe())

            with self.assertRaisesRegex(
                NativeInventoryError,
                "expected PE module is malformed: quotabot.exe",
            ):
                _inventory(root, surface="desktop")

    def test_malformed_code_extension_fails_anywhere(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "bin" / "quotabot.exe", _pe())
            _write(root / "lib" / "later-plugin.dll", b"plain text")

            with self.assertRaisesRegex(
                NativeInventoryError,
                "expected PE module is malformed: lib/later-plugin.dll",
            ):
                _inventory(root)

    def test_truncated_optional_header_is_not_accepted_as_pe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            malformed = bytearray(_pe())
            struct.pack_into("<H", malformed, 0x94, 2)
            _write(root / "bin" / "quotabot.exe", bytes(malformed))

            with self.assertRaisesRegex(
                NativeInventoryError,
                "expected PE module is malformed: bin/quotabot.exe",
            ):
                _inventory(root)

    def test_every_pe_must_match_the_asset_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "bin" / "quotabot.exe", _pe())
            _write(root / "lib" / "arm64.dll", _pe(machine=0xAA64))

            with self.assertRaisesRegex(
                NativeInventoryError,
                "expected x64, observed arm64",
            ):
                _inventory(root)

    def test_arm64_candidate_is_accepted_when_the_asset_matches(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "bin" / "quotabot.exe", _pe(machine=0xAA64))

            result = inventory_native_code(
                root,
                platform="windows",
                surface="cli",
                architecture="arm64",
            )

            self.assertEqual(result.architecture, "arm64")
            self.assertEqual(result.native_code[0].architecture, "arm64")

    def test_candidate_digest_is_deterministic_and_covers_non_native_files(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "bin" / "quotabot.exe", _pe())
            notice = root / "lib" / "notice.txt"
            _write(notice, b"first\n")

            first = _inventory(root)
            repeated = _inventory(root)
            self.assertEqual(first.to_dict(), repeated.to_dict())

            notice.write_bytes(b"second\n")
            changed = _inventory(root)
            self.assertNotEqual(first.candidate_sha256, changed.candidate_sha256)
            self.assertNotEqual(first.inventory_sha256, changed.inventory_sha256)
            self.assertEqual(first.native_code, changed.native_code)

    def test_extracted_candidate_must_match_the_expected_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source"
            extracted = base / "extracted"
            _write(source / "bin" / "quotabot.exe", _pe())
            _write(source / "lib" / "sqlite3.dll", _pe())
            expected = _inventory(source).to_dict()
            manifest = base / "manifest.json"
            manifest.write_text(json.dumps(expected), encoding="utf-8")
            shutil.copytree(source, extracted)

            stdout = io.StringIO()
            with redirect_stdout(stdout):
                matched = native_code_inventory.main(
                    [
                        "--platform",
                        "windows",
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        "--expect-manifest",
                        str(manifest),
                        str(extracted),
                    ]
                )
            self.assertEqual(matched, 0)
            self.assertIn("candidate matches expected inventory", stdout.getvalue())

            _write(extracted / "lib" / "added.dll", _pe())
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                changed = native_code_inventory.main(
                    [
                        "--platform",
                        "windows",
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        "--expect-manifest",
                        str(manifest),
                        str(extracted),
                    ]
                )
            self.assertEqual(changed, 1)
            self.assertIn("candidate changed after inventory", stderr.getvalue())
            self.assertNotIn(str(base), stderr.getvalue())

    @unittest.skipIf(os.name == "nt", "case-distinct fixtures require POSIX")
    def test_case_collisions_fail_for_windows_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = root / "case-sensitivity-probe"
            probe.write_bytes(b"probe")
            if (root / "CASE-SENSITIVITY-PROBE").exists():
                self.skipTest(
                    "case-distinct fixtures require a case-sensitive filesystem"
                )
            probe.unlink()
            _write(root / "bin" / "quotabot.exe", _pe())
            _write(root / "lib" / "Plugin.dll", _pe())
            _write(root / "lib" / "plugin.dll", _pe())

            with self.assertRaisesRegex(
                NativeInventoryError,
                "candidate contains case-colliding paths",
            ):
                _inventory(root)

    @unittest.skipIf(os.name == "nt", "symlink creation is not portable on Windows")
    def test_symbolic_links_and_replacement_links_fail_before_content_read(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "candidate"
            launcher = root / "bin" / "quotabot.exe"
            outside = base / "outside.exe"
            _write(launcher, _pe())
            _write(outside, _pe())
            link = root / "lib" / "linked.dll"
            link.parent.mkdir(parents=True)
            link.symlink_to(outside)
            with self.assertRaisesRegex(
                NativeInventoryError,
                "Windows candidate contains a symbolic link",
            ):
                _inventory(root)

            link.unlink()
            real_open = native_code_inventory.os.open
            resolved_launcher = launcher.resolve(strict=True)
            replaced = False

            def replace_before_open(path: object, flags: int, mode: int = 0o600):
                nonlocal replaced
                if Path(path) == resolved_launcher and not replaced:
                    replaced = True
                    resolved_launcher.unlink()
                    resolved_launcher.symlink_to(outside.resolve(strict=True))
                return real_open(path, flags, mode)

            with mock.patch.object(
                native_code_inventory.os, "open", replace_before_open
            ):
                with self.assertRaisesRegex(
                    NativeInventoryError,
                    "candidate file cannot be opened for inventory",
                ):
                    _inventory(root)

    def test_growth_during_read_is_detected_after_the_bounded_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            launcher = root / "bin" / "quotabot.exe"
            _write(launcher, _pe())
            real_read = native_code_inventory.os.read
            appended = False

            def append_during_read(descriptor: int, count: int) -> bytes:
                nonlocal appended
                chunk = real_read(descriptor, count)
                if not appended:
                    appended = True
                    with launcher.open("ab") as handle:
                        handle.write(b"x")
                return chunk

            with mock.patch.object(
                native_code_inventory.os, "read", append_during_read
            ):
                with self.assertRaisesRegex(
                    NativeInventoryError,
                    "candidate file changed while read",
                ):
                    _inventory(root)

    def test_entry_file_byte_and_native_limits_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "bin" / "quotabot.exe", _pe())
            _write(root / "lib" / "one.dll", _pe())

            limits = (
                ("MAX_CANDIDATE_ENTRIES", 1, "too many entries"),
                ("MAX_CANDIDATE_FILES", 1, "too many files"),
                ("MAX_CANDIDATE_BYTES", 511, "byte limit"),
                ("MAX_NATIVE_CODE", 1, "too many native code files"),
            )
            for name, value, message in limits:
                with self.subTest(limit=name):
                    with mock.patch.object(native_code_inventory, name, value):
                        with self.assertRaisesRegex(NativeInventoryError, message):
                            _inventory(root)

    def test_tree_read_errors_fail_closed_without_disclosing_the_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(
                native_code_inventory.os,
                "scandir",
                side_effect=PermissionError(str(root)),
            ):
                with self.assertRaisesRegex(
                    NativeInventoryError,
                    "candidate tree cannot be read",
                ) as caught:
                    _inventory(root)
            self.assertNotIn(str(root), str(caught.exception))

    def test_json_cli_is_deterministic_and_path_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write(root / "bin" / "quotabot.exe", _pe())
            stdout = io.StringIO()
            stderr = io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = native_code_inventory.main(
                    [
                        "--platform",
                        "windows",
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        "--json",
                        str(root),
                    ]
                )
            self.assertEqual(exit_code, 0, stderr.getvalue())
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["schema"], "quotabot.signing-inventory.v1")
            self.assertEqual(payload["native_code_count"], 1)
            self.assertNotIn(str(root), stdout.getvalue())
            self.assertNotIn("generated_at", payload)

    def test_expected_manifest_read_is_bounded_and_rejects_links(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            manifest.write_bytes(b"x" * 32)
            with mock.patch.object(native_code_inventory, "MAX_MANIFEST_BYTES", 16):
                with self.assertRaisesRegex(
                    NativeInventoryError,
                    "expected inventory manifest is invalid",
                ):
                    native_code_inventory.load_inventory_manifest(manifest)

            if os.name != "nt":
                target = root / "target.json"
                target.write_text(
                    json.dumps({"schema": native_code_inventory.SCHEMA}),
                    encoding="utf-8",
                )
                manifest.unlink()
                manifest.symlink_to(target)
                with self.assertRaisesRegex(
                    NativeInventoryError,
                    "expected inventory manifest is invalid",
                ):
                    native_code_inventory.load_inventory_manifest(manifest)


if __name__ == "__main__":
    unittest.main()
