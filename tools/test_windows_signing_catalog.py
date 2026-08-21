from __future__ import annotations

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools import create_windows_signing_catalog, native_code_inventory


def _pe(machine: int = 0x8664) -> bytes:
    payload = bytearray(1024)
    payload[:2] = b"MZ"
    payload[0x3C:0x40] = (0x80).to_bytes(4, "little")
    payload[0x80:0x84] = b"PE\x00\x00"
    payload[0x84:0x86] = machine.to_bytes(2, "little")
    payload[0x86:0x88] = (1).to_bytes(2, "little")
    payload[0x94:0x96] = (0xF0).to_bytes(2, "little")
    payload[0x96:0x98] = (0x0002).to_bytes(2, "little")
    payload[0x98:0x9A] = (0x20B).to_bytes(2, "little")
    payload[0xD0:0xD4] = (4096).to_bytes(4, "little")
    payload[0xD4:0xD8] = (512).to_bytes(4, "little")
    return bytes(payload)


def _candidate(base: Path) -> tuple[Path, Path]:
    root = base / "bundle"
    (root / "bin").mkdir(parents=True)
    (root / "lib").mkdir()
    (root / "bin" / "quotabot.exe").write_bytes(_pe())
    (root / "lib" / "sqlite3.dll").write_bytes(_pe())
    (root / "README.txt").write_text("candidate\n", encoding="utf-8")
    inventory = native_code_inventory.inventory_native_code(
        root,
        platform="windows",
        surface="cli",
        architecture="x64",
    ).to_dict()
    manifest = base / "unsigned-inventory.json"
    manifest.write_text(json.dumps(inventory), encoding="utf-8")
    return root, manifest


class WindowsSigningCatalogTests(unittest.TestCase):
    def test_catalog_is_exact_relative_sorted_and_path_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest = _candidate(base)
            output = base / "catalog.txt"
            lines = create_windows_signing_catalog.create_windows_signing_catalog(
                root,
                manifest_path=manifest,
                output_path=output,
                surface="cli",
                architecture="x64",
            )
            self.assertEqual(
                lines,
                ("./bundle/bin/quotabot.exe", "./bundle/lib/sqlite3.dll"),
            )
            self.assertEqual(output.read_bytes(), ("\n".join(lines) + "\n").encode())
            self.assertNotIn(str(base), output.read_text(encoding="utf-8"))

    def test_complete_tree_must_still_match_unsigned_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            mutations = {
                "extra": lambda root: (root / "extra.txt").write_text(
                    "extra", encoding="utf-8"
                ),
                "missing": lambda root: (root / "README.txt").unlink(),
                "changed": lambda root: (root / "README.txt").write_text(
                    "changed", encoding="utf-8"
                ),
            }
            for name, mutate in mutations.items():
                with self.subTest(name=name):
                    root, manifest = _candidate(base / name)
                    mutate(root)
                    with self.assertRaises(
                        create_windows_signing_catalog.WindowsSigningCatalogError
                    ) as raised:
                        create_windows_signing_catalog.create_windows_signing_catalog(
                            root,
                            manifest_path=manifest,
                            output_path=root.parent / "catalog.txt",
                            surface="cli",
                            architecture="x64",
                        )
                    self.assertEqual(raised.exception.code, "candidate_changed")

    def test_catalog_parser_rejects_duplicate_escape_and_wrong_native_entry(
        self,
    ) -> None:
        base = {
            "schema": "quotabot.signing-inventory.v1",
            "platform": "windows",
            "surface": "cli",
            "architecture": "x64",
            "native_code_count": 1,
            "native_code": [
                {
                    "path": "bin/quotabot.exe",
                    "kind": "pe",
                    "architecture": "x64",
                    "bytes": 10,
                    "sha256": "a" * 64,
                }
            ],
        }
        invalid_entries = (
            [base["native_code"][0], base["native_code"][0]],
            [{**base["native_code"][0], "path": "../outside.exe"}],
            [{**base["native_code"][0], "kind": "text"}],
        )
        for entries in invalid_entries:
            with self.subTest(entries=entries):
                inventory = {
                    **base,
                    "native_code": entries,
                    "native_code_count": len(entries),
                }
                with self.assertRaises(
                    create_windows_signing_catalog.WindowsSigningCatalogError
                ) as raised:
                    create_windows_signing_catalog._catalog_lines(
                        inventory,
                        root_name="bundle",
                        surface="cli",
                        architecture="x64",
                    )
                self.assertEqual(raised.exception.code, "inventory_invalid")

    def test_output_must_be_regular_and_next_to_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest = _candidate(base)
            with self.assertRaises(
                create_windows_signing_catalog.WindowsSigningCatalogError
            ) as raised:
                create_windows_signing_catalog.create_windows_signing_catalog(
                    root,
                    manifest_path=manifest,
                    output_path=root / "catalog.txt",
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "catalog_path_invalid")

    @unittest.skipIf(os.name == "nt", "symlink creation is not portable on Windows")
    def test_candidate_and_output_links_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest = _candidate(base)
            outside = base / "outside"
            outside.write_bytes(_pe())
            (root / "lib" / "sqlite3.dll").unlink()
            (root / "lib" / "sqlite3.dll").symlink_to(outside)
            with self.assertRaises(
                create_windows_signing_catalog.WindowsSigningCatalogError
            ) as raised:
                create_windows_signing_catalog.create_windows_signing_catalog(
                    root,
                    manifest_path=manifest,
                    output_path=base / "catalog.txt",
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "inventory_invalid")

            root, manifest = _candidate(base / "second")
            output = root.parent / "catalog.txt"
            target = root.parent / "target.txt"
            target.write_text("target", encoding="utf-8")
            output.symlink_to(target)
            with self.assertRaises(
                create_windows_signing_catalog.WindowsSigningCatalogError
            ) as raised:
                create_windows_signing_catalog.create_windows_signing_catalog(
                    root,
                    manifest_path=manifest,
                    output_path=output,
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "catalog_path_invalid")

    def test_junction_or_reparse_detection_from_inventory_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest = _candidate(base)
            real = native_code_inventory._is_junction

            def fake_junction(path: Path, relative: str) -> bool:
                if relative == "lib":
                    return True
                return real(path, relative)

            with (
                mock.patch.object(
                    native_code_inventory,
                    "_is_junction",
                    side_effect=fake_junction,
                ),
                self.assertRaises(
                    create_windows_signing_catalog.WindowsSigningCatalogError
                ) as raised,
            ):
                create_windows_signing_catalog.create_windows_signing_catalog(
                    root,
                    manifest_path=manifest,
                    output_path=base / "catalog.txt",
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "inventory_invalid")

    def test_cli_failure_and_success_are_bounded_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest = _candidate(base)
            output = base / "catalog.txt"
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                status = create_windows_signing_catalog.main(
                    [
                        "--manifest",
                        str(manifest),
                        "--output",
                        str(output),
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        str(root),
                    ]
                )
            self.assertEqual(status, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["schema"], "quotabot.windows-signing-catalog.v1")
            self.assertEqual(payload["native_code_count"], 2)
            self.assertNotIn(str(base), stdout.getvalue())

            (root / "README.txt").write_text("changed", encoding="utf-8")
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                status = create_windows_signing_catalog.main(
                    [
                        "--manifest",
                        str(manifest),
                        "--output",
                        str(output),
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        str(root),
                    ]
                )
            self.assertEqual(status, 1)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(
                payload["schema"], "quotabot.windows-signing-catalog-error.v1"
            )
            self.assertEqual(payload["code"], "candidate_changed")
            self.assertNotIn(str(base), stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
