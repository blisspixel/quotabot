"""Tests for exact Windows Authenticode signing-delta validation."""

from __future__ import annotations

import io
import json
import struct
import tempfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest import TestCase, main as unittest_main, mock

from tools import validate_windows_signing_delta as validator
from tools.native_code_inventory import canonical_sha256, inventory_native_code
from tools.validate_windows_signing_delta import (
    ERROR_SCHEMA,
    SCHEMA,
    WindowsSigningDeltaError,
    main,
    validate_windows_signing_delta,
)


_PE_OFFSET = 0x80
_OPTIONAL_OFFSET = _PE_OFFSET + 24
_CHECKSUM_OFFSET = _OPTIONAL_OFFSET + 64
_SECURITY_DIRECTORY_OFFSET = _OPTIONAL_OFFSET + 112 + 4 * 8


def _minimal_pe(label: bytes, *, overlay: bytes = b"") -> bytes:
    payload = bytearray(0x400)
    payload[:2] = b"MZ"
    struct.pack_into("<I", payload, 0x3C, _PE_OFFSET)
    payload[_PE_OFFSET : _PE_OFFSET + 4] = b"PE\x00\x00"
    struct.pack_into(
        "<HHIIIHH",
        payload,
        _PE_OFFSET + 4,
        0x8664,
        1,
        0,
        0,
        0,
        0xF0,
        0x0022,
    )
    struct.pack_into("<H", payload, _OPTIONAL_OFFSET, 0x20B)
    struct.pack_into("<I", payload, _OPTIONAL_OFFSET + 56, 0x2000)
    struct.pack_into("<I", payload, _OPTIONAL_OFFSET + 60, 0x200)
    struct.pack_into("<I", payload, _CHECKSUM_OFFSET, 0x11111111)
    struct.pack_into("<I", payload, _OPTIONAL_OFFSET + 108, 16)
    struct.pack_into("<II", payload, _SECURITY_DIRECTORY_OFFSET, 0, 0)
    section = _OPTIONAL_OFFSET + 0xF0
    payload[section : section + 8] = b".text\x00\x00\x00"
    struct.pack_into("<IIII", payload, section + 8, 0x200, 0x1000, 0x200, 0x200)
    struct.pack_into("<I", payload, section + 36, 0x60000020)
    payload[0x200 : 0x200 + len(label)] = label
    payload[0x280:0x28D] = b"RESOURCE-DATA"
    payload[0x300:0x30B] = b"IMPORT-DATA"
    return bytes(payload) + overlay


def _certificate_record(data: bytes = b"PKCS7-SIGNED-DATA") -> bytes:
    length = 8 + len(data)
    record = struct.pack("<IHH", length, 0x0200, 0x0002) + data
    return record + b"\x00" * ((-len(record)) % 8)


def _signed_pe(unsigned: bytes, *, certificate: bytes | None = None) -> bytes:
    certificate_table = _certificate_record() if certificate is None else certificate
    certificate_offset = (len(unsigned) + 7) & ~7
    payload = bytearray(unsigned)
    payload.extend(b"\x00" * (certificate_offset - len(payload)))
    payload.extend(certificate_table)
    struct.pack_into("<I", payload, _CHECKSUM_OFFSET, 0x22222222)
    struct.pack_into(
        "<II",
        payload,
        _SECURITY_DIRECTORY_OFFSET,
        certificate_offset,
        len(certificate_table),
    )
    return bytes(payload)


def _write_candidate(
    root: Path,
    executable: bytes,
    library: bytes,
    *,
    readme: bytes = b"readme",
    extra_files: dict[str, bytes] | None = None,
) -> None:
    (root / "bin").mkdir(parents=True)
    (root / "lib").mkdir()
    (root / "bin" / "quotabot.exe").write_bytes(executable)
    (root / "lib" / "sqlite3.dll").write_bytes(library)
    (root / "README.txt").write_bytes(readme)
    for relative, payload in (extra_files or {}).items():
        target = root.joinpath(*relative.split("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)


def _inventory(root: Path, *, surface: str = "cli") -> dict[str, object]:
    return inventory_native_code(
        root,
        platform="windows",
        surface=surface,
        architecture="x64",
    ).to_dict()


def _publish_json(path: Path, value: dict[str, object]) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n",
        encoding="ascii",
    )


def _publish_catalog(path: Path, native_paths: list[str]) -> bytes:
    payload = (
        "\n".join(f"./candidate/{relative}" for relative in sorted(native_paths)) + "\n"
    ).encode("ascii")
    path.write_bytes(payload)
    return payload


class WindowsSigningDeltaTests(TestCase):
    def _fixture(
        self,
        base: Path,
        *,
        before_exe: bytes | None = None,
        before_dll: bytes | None = None,
        after_exe: bytes | None = None,
        after_dll: bytes | None = None,
        before_readme: bytes = b"readme",
        after_readme: bytes = b"readme",
        before_extra: dict[str, bytes] | None = None,
        after_extra: dict[str, bytes] | None = None,
        catalog_paths: list[str] | None = None,
    ) -> tuple[Path, Path, Path, Path, Path]:
        before_root = base / "before-root"
        after_root = base / "after-root"
        unsigned_exe = before_exe or _minimal_pe(b"EXE-CODE")
        unsigned_dll = before_dll or _minimal_pe(b"DLL-CODE")
        _write_candidate(
            before_root,
            unsigned_exe,
            unsigned_dll,
            readme=before_readme,
            extra_files=before_extra,
        )
        _write_candidate(
            after_root,
            after_exe or _signed_pe(unsigned_exe),
            after_dll or _signed_pe(unsigned_dll),
            readme=after_readme,
            extra_files=after_extra,
        )
        before_manifest = base / "before.json"
        after_manifest = base / "after.json"
        catalog = base / "catalog.txt"
        _publish_json(before_manifest, _inventory(before_root))
        _publish_json(after_manifest, _inventory(after_root))
        _publish_catalog(
            catalog,
            catalog_paths or ["bin/quotabot.exe", "lib/sqlite3.dll"],
        )
        return before_manifest, after_manifest, catalog, before_root, after_root

    def assert_delta_error(
        self,
        code: str,
        paths: tuple[Path, Path, Path, Path, Path],
    ) -> None:
        with self.assertRaisesRegex(WindowsSigningDeltaError, f"^{code}$"):
            validate_windows_signing_delta(*paths)

    def test_authentic_checksum_directory_padding_and_certificates_are_accepted(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            unsigned_exe = _minimal_pe(b"EXE-CODE", overlay=b"EXE-OVERLAY")
            unsigned_dll = _minimal_pe(b"DLL-CODE", overlay=b"DLL-OVERLAY-123")
            paths = self._fixture(
                base,
                before_exe=unsigned_exe,
                before_dll=unsigned_dll,
                after_exe=_signed_pe(
                    unsigned_exe,
                    certificate=_certificate_record(b"FIRST")
                    + _certificate_record(b"SECOND"),
                ),
                after_dll=_signed_pe(unsigned_dll),
            )
            first = validate_windows_signing_delta(*paths)
            second = validate_windows_signing_delta(*paths)

            self.assertEqual(first, second)
            self.assertEqual(first["schema"], SCHEMA)
            self.assertEqual(first["planned_native_count"], 2)
            self.assertEqual(first["changed_native_count"], 2)
            self.assertRegex(str(first["normalized_images_sha256"]), r"^[0-9a-f]{64}$")
            self.assertRegex(str(first["certificate_tables_sha256"]), r"^[0-9a-f]{64}$")
            body = {
                key: value
                for key, value in first.items()
                if key != "receipt_body_sha256"
            }
            self.assertEqual(first["receipt_body_sha256"], canonical_sha256(body))

    def test_noncatalog_added_removed_unchanged_and_extra_pe_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            cases = {
                "noncatalog": (
                    {"after_readme": b"changed"},
                    "content_changed_outside_catalog",
                ),
                "added": (
                    {"after_extra": {"unexpected.txt": b"unexpected"}},
                    "path_added",
                ),
                "unchanged": (
                    {"after_dll": _minimal_pe(b"DLL-CODE")},
                    "planned_native_unchanged",
                ),
                "extra_pe": (
                    {"after_extra": {"plugins/extra.dll": _minimal_pe(b"EXTRA-CODE")}},
                    "native_set_changed",
                ),
            }
            for index, (label, (options, code)) in enumerate(cases.items()):
                with self.subTest(label=label):
                    case_base = base / str(index)
                    case_base.mkdir()
                    self.assert_delta_error(code, self._fixture(case_base, **options))

            removed_base = base / "removed"
            removed_paths = self._fixture(removed_base)
            (removed_paths[4] / "README.txt").unlink()
            _publish_json(removed_paths[1], _inventory(removed_paths[4]))
            self.assert_delta_error("path_removed", removed_paths)

    def test_code_resource_import_header_and_overlay_mutations_are_rejected(
        self,
    ) -> None:
        unsigned = _minimal_pe(b"ORIGINAL-CODE", overlay=b"ORIGINAL-OVERLAY")
        mutations = {
            "code": 0x220,
            "resource": 0x284,
            "import": 0x304,
            "header": _OPTIONAL_OFFSET + 40,
            "overlay": len(unsigned) - 2,
        }
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for index, (label, offset) in enumerate(mutations.items()):
                with self.subTest(label=label):
                    changed = bytearray(unsigned)
                    changed[offset] ^= 0x5A
                    case_base = base / str(index)
                    case_base.mkdir()
                    paths = self._fixture(
                        case_base,
                        before_exe=unsigned,
                        after_exe=_signed_pe(bytes(changed)),
                    )
                    self.assert_delta_error("pe_content_changed", paths)

    def test_wrong_directory_trailing_bytes_and_invalid_gap_fail(self) -> None:
        unsigned = _minimal_pe(b"EXE-CODE", overlay=b"unaligned-overlay")
        valid = _signed_pe(unsigned)
        certificate_offset, certificate_size = struct.unpack_from(
            "<II", valid, _SECURITY_DIRECTORY_OFFSET
        )
        wrong_offset = bytearray(valid)
        struct.pack_into(
            "<II",
            wrong_offset,
            _SECURITY_DIRECTORY_OFFSET,
            len(unsigned) - 8,
            certificate_size,
        )
        trailing = valid + b"TRAILING"
        nonzero_gap = bytearray(valid)
        self.assertGreater(certificate_offset, len(unsigned))
        nonzero_gap[len(unsigned)] = 1
        oversized_gap = bytearray(valid)
        oversized_gap[certificate_offset:certificate_offset] = bytes(8)
        struct.pack_into(
            "<II",
            oversized_gap,
            _SECURITY_DIRECTORY_OFFSET,
            certificate_offset + 8,
            certificate_size,
        )
        cases = (
            bytes(wrong_offset),
            trailing,
            bytes(nonzero_gap),
            bytes(oversized_gap),
        )
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for index, after in enumerate(cases):
                with self.subTest(index=index):
                    case_base = base / str(index)
                    case_base.mkdir()
                    paths = self._fixture(
                        case_base,
                        before_exe=unsigned,
                        after_exe=after,
                    )
                    self.assert_delta_error("pe_authenticode_invalid", paths)

    def test_malformed_certificate_records_are_rejected(self) -> None:
        unsigned = _minimal_pe(b"EXE-CODE")
        valid_record = bytearray(_certificate_record(b"CERTIFICATE"))
        cases: list[bytes] = []
        wrong_revision = bytearray(valid_record)
        struct.pack_into("<H", wrong_revision, 4, 0x0100)
        cases.append(bytes(wrong_revision))
        wrong_type = bytearray(valid_record)
        struct.pack_into("<H", wrong_type, 6, 0x0001)
        cases.append(bytes(wrong_type))
        bad_length = bytearray(valid_record)
        struct.pack_into("<I", bad_length, 0, len(bad_length) + 8)
        cases.append(bytes(bad_length))
        padded = bytearray(_certificate_record(b"X"))
        padded[-1] = 1
        cases.append(bytes(padded))
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for index, record in enumerate(cases):
                with self.subTest(index=index):
                    case_base = base / str(index)
                    case_base.mkdir()
                    paths = self._fixture(
                        case_base,
                        before_exe=unsigned,
                        after_exe=_signed_pe(unsigned, certificate=record),
                    )
                    self.assert_delta_error("pe_authenticode_invalid", paths)

    def test_preexisting_certificate_and_changed_pe_layout_are_rejected(self) -> None:
        unsigned = _minimal_pe(b"EXE-CODE")
        pre_signed = _signed_pe(unsigned)
        pe32 = bytearray(_signed_pe(unsigned))
        struct.pack_into("<H", pe32, _OPTIONAL_OFFSET, 0x10B)
        struct.pack_into("<I", pe32, _OPTIONAL_OFFSET + 92, 16)
        certificate_offset, certificate_size = struct.unpack_from(
            "<II", pe32, _SECURITY_DIRECTORY_OFFSET
        )
        struct.pack_into("<II", pe32, _SECURITY_DIRECTORY_OFFSET, 0, 0)
        struct.pack_into(
            "<II",
            pe32,
            _OPTIONAL_OFFSET + 96 + 4 * 8,
            certificate_offset,
            certificate_size,
        )
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            preexisting = self._fixture(
                base / "preexisting",
                before_exe=pre_signed,
                after_exe=_signed_pe(pre_signed),
            )
            self.assert_delta_error("pe_preexisting_certificate", preexisting)
            changed_layout = self._fixture(
                base / "layout",
                before_exe=unsigned,
                after_exe=bytes(pe32),
            )
            self.assert_delta_error("pe_layout_changed", changed_layout)

    def test_malformed_pe_headers_are_rejected_by_the_byte_level_gate(self) -> None:
        unsigned = _minimal_pe(b"EXE-CODE")
        malformed = bytearray(_signed_pe(unsigned))
        struct.pack_into("<I", malformed, 0x3C, len(malformed) + 1)
        with self.assertRaisesRegex(WindowsSigningDeltaError, "^pe_invalid$"):
            validator._validate_authenticode_insertion(unsigned, bytes(malformed))

    def test_catalog_mismatch_malformed_paths_and_scope_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            paths = self._fixture(base, catalog_paths=["bin/quotabot.exe"])
            self.assert_delta_error("catalog_mismatch", paths)
            _publish_catalog(paths[2], ["bin/Quotabot.exe", "bin/quotabot.exe"])
            self.assert_delta_error("catalog_invalid", paths)

            manifest = json.loads(paths[1].read_text(encoding="ascii"))
            manifest["surface"] = "desktop"
            body = {
                key: value
                for key, value in manifest.items()
                if key != "inventory_sha256"
            }
            manifest["inventory_sha256"] = canonical_sha256(body)
            _publish_json(paths[1], manifest)
            self.assert_delta_error("scope_mismatch", paths)

    def test_root_manifest_mismatch_and_root_race_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            mismatch = self._fixture(base / "mismatch")
            (mismatch[3] / "README.txt").write_bytes(b"changed after manifest")
            self.assert_delta_error("root_manifest_mismatch", mismatch)

            raced = self._fixture(base / "race")
            original_inventory = validator.inventory_native_code
            calls = 0

            def racing_inventory(*args: object, **kwargs: object):
                nonlocal calls
                calls += 1
                if calls == 3:
                    (raced[3] / "README.txt").write_bytes(b"changed during read")
                return original_inventory(*args, **kwargs)

            with mock.patch.object(
                validator,
                "inventory_native_code",
                side_effect=racing_inventory,
            ):
                self.assert_delta_error("root_unstable", raced)

    def test_manifest_instability_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self._fixture(Path(directory))
            original_load = validator._load_inventory
            calls = 0

            def racing_load(path: Path) -> dict[str, object]:
                nonlocal calls
                calls += 1
                value = original_load(path)
                if calls == 3:
                    return {
                        **value,
                        "candidate_bytes": int(value["candidate_bytes"]) + 1,
                    }
                return value

            with mock.patch.object(
                validator,
                "_load_inventory",
                side_effect=racing_load,
            ):
                self.assert_delta_error("input_unstable", paths)

    def _arguments(
        self,
        paths: tuple[Path, Path, Path, Path, Path],
        receipt: Path,
    ) -> list[str]:
        return [
            "--before",
            str(paths[0]),
            "--after",
            str(paths[1]),
            "--catalog",
            str(paths[2]),
            "--before-root",
            str(paths[3]),
            "--after-root",
            str(paths[4]),
            "--receipt",
            str(receipt),
        ]

    def test_cli_atomically_replaces_receipts_and_writes_bounded_failures(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            paths = self._fixture(base)
            receipt = base / "receipt.json"
            receipt.write_text("prior", encoding="ascii")
            arguments = self._arguments(paths, receipt)
            with redirect_stdout(io.StringIO()):
                result = main(arguments)
            self.assertEqual(result, 0)
            success = json.loads(receipt.read_text(encoding="ascii"))
            self.assertEqual(success["schema"], SCHEMA)
            self.assertLess(receipt.stat().st_size, 128 * 1024)

            (paths[4] / "README.txt").write_bytes(b"tampered")
            _publish_json(paths[1], _inventory(paths[4]))
            with redirect_stdout(io.StringIO()):
                failure_result = main(arguments)
            self.assertEqual(failure_result, 1)
            failure = json.loads(receipt.read_text(encoding="ascii"))
            self.assertEqual(failure["schema"], ERROR_SCHEMA)
            self.assertEqual(failure["code"], "content_changed_outside_catalog")
            self.assertNotIn(str(base), receipt.read_text(encoding="ascii"))

    def test_receipt_output_failure_preserves_inputs_and_prior_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            paths = self._fixture(base)
            original_before = paths[0].read_bytes()
            output = io.StringIO()
            with redirect_stdout(output):
                result = main(self._arguments(paths, paths[0]))
            self.assertEqual(result, 1)
            failure = json.loads(output.getvalue())
            self.assertEqual(failure["code"], "receipt_path_invalid")
            self.assertEqual(failure["receipt_error_code"], "receipt_path_invalid")
            self.assertEqual(paths[0].read_bytes(), original_before)

            receipt = base / "replace.json"
            receipt.write_text("prior evidence", encoding="ascii")
            with (
                mock.patch.object(
                    validator.os,
                    "replace",
                    side_effect=OSError("private replacement failure"),
                ),
                redirect_stdout(output := io.StringIO()),
            ):
                replace_result = main(self._arguments(paths, receipt))
            self.assertEqual(replace_result, 1)
            replacement_failure = json.loads(output.getvalue())
            self.assertEqual(replacement_failure["code"], "receipt_write_failed")
            self.assertEqual(receipt.read_text(encoding="ascii"), "prior evidence")

    def test_receipt_cannot_be_published_inside_a_validated_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self._fixture(Path(directory))
            output = io.StringIO()
            with redirect_stdout(output):
                result = main(self._arguments(paths, paths[4] / "receipt.json"))
            self.assertEqual(result, 1)
            self.assertEqual(
                json.loads(output.getvalue())["code"], "receipt_path_invalid"
            )


if __name__ == "__main__":
    unittest_main()
