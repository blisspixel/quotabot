"""Tests for bounded Windows Authenticode policy verification."""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tools.native_code_inventory import inventory_native_code
from tools import verify_windows_signatures, windows_timestamp_policy
from tools.verify_windows_signatures import (
    AuthenticodeMetadata,
    WindowsSignatureVerificationError,
)


VALID_SIGNTOOL_OUTPUT = b"""File: hidden
Index  Algorithm  Timestamp
========================================
0      sha256     RFC3161

Successfully verified: hidden
"""

SIGNED_DATA_OID = bytes.fromhex("2a864886f70d010702")
RFC3161_ATTRIBUTE_OID = bytes.fromhex("2b060104018237030301")
STANDARD_TIMESTAMP_ATTRIBUTE_OID = bytes.fromhex("2a864886f70d010910020e")
TST_INFO_OID = bytes.fromhex("2a864886f70d0109100104")
SHA256_OID = bytes.fromhex("608648016503040201")
SHA1_OID = bytes.fromhex("2b0e03021a")
RSA_OID = bytes.fromhex("2a864886f70d010101")
SPC_INDIRECT_DATA_OID = bytes.fromhex("2b060104018237020104")


def _der(tag: int, content: bytes) -> bytes:
    length = len(content)
    if length < 128:
        encoded_length = bytes([length])
    else:
        raw_length = length.to_bytes((length.bit_length() + 7) // 8, "big")
        encoded_length = bytes([0x80 | len(raw_length)]) + raw_length
    return bytes([tag]) + encoded_length + content


def _algorithm_identifier(oid: bytes) -> bytes:
    return _der(0x30, _der(0x06, oid) + _der(0x05, b""))


def _signer_info(
    unsigned_attributes: bytes | None = None,
    *,
    signer_identifier_tag: int = 0x30,
    signature: bytes = b"signature",
) -> bytes:
    content = (
        _der(0x02, b"\x01")
        + _der(signer_identifier_tag, b"")
        + _algorithm_identifier(SHA256_OID)
        + _algorithm_identifier(RSA_OID)
        + _der(0x04, signature)
    )
    if unsigned_attributes is not None:
        content += _der(0xA1, unsigned_attributes)
    return _der(0x30, content)


def _signed_data(
    encapsulated_content: bytes,
    signer_infos: bytes,
    *,
    content_type_oid: bytes = SIGNED_DATA_OID,
) -> bytes:
    content = (
        _der(0x02, b"\x03")
        + _der(0x31, _algorithm_identifier(SHA256_OID))
        + encapsulated_content
        + _der(0x31, signer_infos)
    )
    return _der(
        0x30,
        _der(0x06, content_type_oid) + _der(0xA0, _der(0x30, content)),
    )


def _timestamp_token(
    *,
    hash_oid: bytes = SHA256_OID,
    imprint: bytes | None = None,
    signer_count: int = 1,
    content_type_oid: bytes = SIGNED_DATA_OID,
    tst_info_oid: bytes = TST_INFO_OID,
    generated_time: bytes = b"20260728120000Z",
    signer_identifier_tag: int = 0x30,
    signer_signature: bytes = b"signature",
) -> bytes:
    if imprint is None:
        imprint = hashlib.sha256(b"signature").digest()
    message_imprint = _der(
        0x30,
        _algorithm_identifier(hash_oid) + _der(0x04, imprint),
    )
    tst_info = _der(
        0x30,
        _der(0x02, b"\x01")
        + _der(0x06, bytes.fromhex("2b0601040184590a0301"))
        + message_imprint
        + _der(0x02, b"\x01")
        + _der(0x18, generated_time),
    )
    encapsulated = _der(
        0x30,
        _der(0x06, tst_info_oid) + _der(0xA0, _der(0x04, tst_info)),
    )
    signer_info = _signer_info(
        signer_identifier_tag=signer_identifier_tag,
        signature=signer_signature,
    )
    return _signed_data(
        encapsulated,
        signer_info * signer_count,
        content_type_oid=content_type_oid,
    )


def _authenticode_pkcs7(
    *,
    hash_oid: bytes = SHA256_OID,
    imprint: bytes | None = None,
    timestamp_attribute_count: int = 1,
    timestamp_value_count: int = 1,
    outer_signer_count: int = 1,
    token_signer_count: int = 1,
    include_unsigned_attributes: bool = True,
    extra_unsigned_attribute_oid: bytes | None = None,
    outer_content_type_oid: bytes = SIGNED_DATA_OID,
    outer_signer_identifier_tag: int = 0x30,
    outer_signature: bytes = b"signature",
    tst_info_oid: bytes = TST_INFO_OID,
    generated_time: bytes = b"20260728120000Z",
) -> bytes:
    if imprint is None:
        imprint = hashlib.sha256(outer_signature).digest()
    token = _timestamp_token(
        hash_oid=hash_oid,
        imprint=imprint,
        signer_count=token_signer_count,
        tst_info_oid=tst_info_oid,
        generated_time=generated_time,
    )
    timestamp_attribute = _der(
        0x30,
        _der(0x06, RFC3161_ATTRIBUTE_OID) + _der(0x31, token * timestamp_value_count),
    )
    unsigned_attributes = timestamp_attribute * timestamp_attribute_count
    if extra_unsigned_attribute_oid is not None:
        unsigned_attributes += _der(
            0x30,
            _der(0x06, extra_unsigned_attribute_oid) + _der(0x31, _der(0x04, b"other")),
        )
    outer_signer = _signer_info(
        unsigned_attributes if include_unsigned_attributes else None,
        signer_identifier_tag=outer_signer_identifier_tag,
        signature=outer_signature,
    )
    encapsulated = _der(0x30, _der(0x06, SPC_INDIRECT_DATA_OID))
    return _signed_data(
        encapsulated,
        outer_signer * outer_signer_count,
        content_type_oid=outer_content_type_oid,
    )


def _pe() -> bytes:
    payload = bytearray(512)
    payload[0:2] = b"MZ"
    struct.pack_into("<I", payload, 0x3C, 0x80)
    payload[0x80:0x84] = b"PE\x00\x00"
    struct.pack_into("<HHIIIHH", payload, 0x84, 0x8664, 1, 0, 0, 0, 0xF0, 0x2022)
    struct.pack_into("<H", payload, 0x98, 0x20B)
    struct.pack_into("<II", payload, 0xD0, 4096, 512)
    return bytes(payload)


def _pe_with_certificate(
    pkcs7: bytes,
    *,
    certificate_count: int = 1,
    nonzero_der_trailer: bool = False,
) -> bytes:
    payload = bytearray(_pe())
    optional_header = 0x98
    struct.pack_into("<I", payload, optional_header + 108, 16)
    certificate_offset = (len(payload) + 7) & ~7
    payload.extend(b"\x00" * (certificate_offset - len(payload)))

    records = bytearray()
    for _ in range(certificate_count):
        certificate = pkcs7 + (b"\x01" if nonzero_der_trailer else b"")
        record_length = (8 + len(certificate) + 7) & ~7
        record = bytearray(record_length)
        struct.pack_into("<IHH", record, 0, record_length, 0x0200, 0x0002)
        record[8 : 8 + len(certificate)] = certificate
        records.extend(record)
    struct.pack_into(
        "<II",
        payload,
        optional_header + 112 + (4 * 8),
        certificate_offset,
        len(records),
    )
    payload.extend(records)
    return bytes(payload)


def _write_signed_pe(base: Path, pkcs7: bytes, **kwargs) -> Path:
    target = base / "signed.exe"
    target.write_bytes(_pe_with_certificate(pkcs7, **kwargs))
    return target


def _write_manifest(root: Path, manifest: Path, *, surface: str = "cli") -> None:
    inventory = inventory_native_code(
        root,
        platform="windows",
        surface=surface,
        architecture="x64",
    )
    manifest.write_text(
        json.dumps(inventory.to_dict(), separators=(",", ":"), sort_keys=True),
        encoding="utf-8",
    )


class SignaturePolicyTests(unittest.TestCase):
    def test_cli_exposes_no_native_tool_override(self) -> None:
        help_text = verify_windows_signatures._parser().format_help()
        self.assertNotIn("--signtool", help_text)
        self.assertNotIn("--powershell", help_text)

    def test_valid_sha256_message_imprint_is_extracted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = _write_signed_pe(Path(directory), _authenticode_pkcs7())
            evidence = verify_windows_signatures._read_timestamp_message_imprint(target)

        self.assertEqual(evidence.algorithm, "sha256")
        self.assertEqual(evidence.digest, hashlib.sha256(b"signature").hexdigest())

    def test_weak_or_wrong_length_message_imprint_fails_closed(self) -> None:
        cases = (
            _authenticode_pkcs7(
                hash_oid=SHA1_OID,
                imprint=hashlib.sha1(b"signature", usedforsecurity=False).digest(),
            ),
            _authenticode_pkcs7(imprint=b"i" * 31),
            _authenticode_pkcs7(imprint=b"i" * 32),
        )
        for index, pkcs7 in enumerate(cases):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                target = _write_signed_pe(Path(directory), pkcs7)
                with self.assertRaises(WindowsSignatureVerificationError) as caught:
                    verify_windows_signatures._read_timestamp_message_imprint(target)
                self.assertEqual(caught.exception.code, "timestamp_policy_unproven")

    def test_der_reader_rejects_noncanonical_or_truncated_values(self) -> None:
        invalid = (
            b"",
            b"\x04",
            b"\x04\x80",
            b"\x04\x81\x01x",
            b"\x04\x82\x00\x80" + (b"x" * 128),
            b"\x04\x02x",
            b"\x1f\x00",
        )
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    windows_timestamp_policy._DerReader(value).read()

        oid = windows_timestamp_policy._DerValue(
            tag=0x06,
            content=memoryview(b"\x80\x00"),
        )
        with self.assertRaises(ValueError):
            windows_timestamp_policy._validate_oid(oid)

        integer = windows_timestamp_policy._DerValue(
            tag=0x02,
            content=memoryview(b"\x00\x01"),
        )
        with self.assertRaises(ValueError):
            windows_timestamp_policy._validate_integer(integer)

        algorithm = _der(0x30, _der(0x06, SHA256_OID))
        reader = windows_timestamp_policy._DerReader(algorithm)
        self.assertEqual(
            windows_timestamp_policy._read_algorithm_oid(reader),
            SHA256_OID,
        )
        reader.finish()

        parameterized = _der(
            0x30,
            _der(0x06, SHA256_OID) + _der(0x30, b""),
        )
        with self.assertRaises(ValueError):
            windows_timestamp_policy._read_algorithm_oid(
                windows_timestamp_policy._DerReader(parameterized),
                null_parameters_only=True,
            )

    def test_missing_or_ambiguous_timestamp_evidence_fails_closed(self) -> None:
        cases = (
            _authenticode_pkcs7(timestamp_attribute_count=0),
            _authenticode_pkcs7(timestamp_attribute_count=2),
            _authenticode_pkcs7(timestamp_value_count=2),
            _authenticode_pkcs7(outer_signer_count=2),
            _authenticode_pkcs7(token_signer_count=2),
            _authenticode_pkcs7(include_unsigned_attributes=False),
            _authenticode_pkcs7(
                extra_unsigned_attribute_oid=STANDARD_TIMESTAMP_ATTRIBUTE_OID
            ),
            _authenticode_pkcs7(outer_content_type_oid=SPC_INDIRECT_DATA_OID),
            _authenticode_pkcs7(outer_signer_identifier_tag=0x04),
            _authenticode_pkcs7(outer_signature=b""),
            _authenticode_pkcs7(tst_info_oid=SPC_INDIRECT_DATA_OID),
            _authenticode_pkcs7(generated_time=b""),
        )
        for index, pkcs7 in enumerate(cases):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                target = _write_signed_pe(Path(directory), pkcs7)
                with self.assertRaises(WindowsSignatureVerificationError) as caught:
                    verify_windows_signatures._read_timestamp_message_imprint(target)
                self.assertEqual(caught.exception.code, "timestamp_policy_unproven")

    def test_pe_certificate_directory_rejection_paths_fail_closed(self) -> None:
        pkcs7 = _authenticode_pkcs7()
        valid = _pe_with_certificate(pkcs7)
        security_entry = 0x98 + 112 + (4 * 8)
        certificate_offset = struct.unpack_from("<I", valid, security_entry)[0]
        original_record_length = struct.unpack_from("<I", valid, certificate_offset)[0]

        cases: list[bytearray] = []

        missing_directory = bytearray(valid)
        struct.pack_into("<I", missing_directory, 0x98 + 108, 0)
        cases.append(missing_directory)

        unaligned_offset = bytearray(valid)
        struct.pack_into("<I", unaligned_offset, security_entry, certificate_offset + 1)
        cases.append(unaligned_offset)

        short_table = bytearray(valid)
        struct.pack_into("<I", short_table, security_entry + 4, 7)
        cases.append(short_table)

        wrong_revision = bytearray(valid)
        struct.pack_into("<H", wrong_revision, certificate_offset + 4, 0x0100)
        cases.append(wrong_revision)

        wrong_type = bytearray(valid)
        struct.pack_into("<H", wrong_type, certificate_offset + 6, 0x0001)
        cases.append(wrong_type)

        short_record = bytearray(valid)
        struct.pack_into("<I", short_record, certificate_offset, 7)
        cases.append(short_record)

        nonzero_alignment = bytearray(valid)
        struct.pack_into(
            "<I",
            nonzero_alignment,
            certificate_offset,
            original_record_length - 1,
        )
        nonzero_alignment[certificate_offset + original_record_length - 1] = 1
        cases.append(nonzero_alignment)

        unsupported_optional_header = bytearray(valid)
        struct.pack_into("<H", unsupported_optional_header, 0x98, 0x0107)
        cases.append(unsupported_optional_header)

        for index, payload in enumerate(cases):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / "signed.exe"
                target.write_bytes(payload)
                with self.assertRaises(WindowsSignatureVerificationError) as caught:
                    verify_windows_signatures._read_timestamp_message_imprint(target)
                self.assertEqual(caught.exception.code, "timestamp_policy_unproven")

    def test_malformed_der_and_certificate_layout_fail_closed(self) -> None:
        valid = _authenticode_pkcs7()
        indefinite = bytes([valid[0], 0x80]) + valid[2:]
        cases = (
            (indefinite, {}),
            (valid, {"nonzero_der_trailer": True}),
            (valid, {"certificate_count": 2}),
        )
        for index, (pkcs7, options) in enumerate(cases):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                target = _write_signed_pe(Path(directory), pkcs7, **options)
                with self.assertRaises(WindowsSignatureVerificationError) as caught:
                    verify_windows_signatures._read_timestamp_message_imprint(target)
                self.assertEqual(caught.exception.code, "timestamp_policy_unproven")

    def test_truncated_oversized_and_resource_limited_inputs_fail_closed(self) -> None:
        valid = _authenticode_pkcs7()
        with tempfile.TemporaryDirectory() as directory:
            target = _write_signed_pe(Path(directory), valid)
            truncated = bytearray(target.read_bytes())
            struct.pack_into("<I", truncated, 0x98 + 112 + (4 * 8) + 4, 0x100000)
            target.write_bytes(truncated)
            with self.assertRaises(WindowsSignatureVerificationError) as caught:
                verify_windows_signatures._read_timestamp_message_imprint(target)
            self.assertEqual(caught.exception.code, "timestamp_policy_unproven")

        limits = (
            ("MAX_PE_CERTIFICATE_TABLE_BYTES", 8),
            ("MAX_DER_ELEMENTS", 2),
            ("MAX_DER_DEPTH", 2),
        )
        for name, value in limits:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                target = _write_signed_pe(Path(directory), valid)
                with (
                    mock.patch.object(windows_timestamp_policy, name, value),
                    self.assertRaises(WindowsSignatureVerificationError) as caught,
                ):
                    verify_windows_signatures._read_timestamp_message_imprint(target)
                self.assertEqual(caught.exception.code, "timestamp_policy_unproven")

    def test_signtool_policy_requires_one_sha256_rfc3161_signature(self) -> None:
        self.assertEqual(
            verify_windows_signatures.parse_signtool_policy(VALID_SIGNTOOL_OUTPUT),
            ("sha256", "rfc3161"),
        )

        invalid = (
            b"0 sha1 RFC3161\n",
            b"0 sha256 Authenticode\n",
            b"0 sha256 RFC3161\n1 sha256 RFC3161\n",
            b"no signature table\n",
        )
        for output in invalid:
            with self.subTest(output=output):
                with self.assertRaisesRegex(
                    WindowsSignatureVerificationError,
                    "policy could not be proven",
                ):
                    verify_windows_signatures.parse_signtool_policy(output)

    def test_signtool_policy_rejects_oversized_output(self) -> None:
        with mock.patch.object(
            verify_windows_signatures,
            "MAX_NATIVE_OUTPUT_BYTES",
            4,
        ):
            with self.assertRaisesRegex(
                WindowsSignatureVerificationError,
                "output exceeded",
            ):
                verify_windows_signatures.parse_signtool_policy(b"12345")

    def test_expected_identity_is_strict_and_normalized(self) -> None:
        self.assertEqual(
            verify_windows_signatures._normalize_thumbprint("aa " * 20),
            "AA" * 20,
        )
        for thumbprint in ("", "A" * 39, "G" * 40):
            with self.subTest(thumbprint=thumbprint):
                with self.assertRaisesRegex(
                    WindowsSignatureVerificationError,
                    "expected signer policy is invalid",
                ):
                    verify_windows_signatures._normalize_thumbprint(thumbprint)
        for subject in ("", " CN=Example", "CN=Example\nInjected"):
            with self.subTest(subject=subject):
                with self.assertRaisesRegex(
                    WindowsSignatureVerificationError,
                    "expected signer policy is invalid",
                ):
                    verify_windows_signatures._validate_subject(subject)

    def test_bounded_verifier_helpers_fail_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown verification error code"):
            WindowsSignatureVerificationError("not_a_public_error")
        with self.assertRaisesRegex(
            WindowsSignatureVerificationError,
            "timed out",
        ):
            verify_windows_signatures._remaining_timeout(time.monotonic() - 1)
        for value in (None, "", "x" * 513, "CN=Expected\nInjected"):
            with self.subTest(value=value):
                self.assertIsNone(
                    verify_windows_signatures._bounded_certificate_field(value)
                )

        with tempfile.TemporaryDirectory() as temporary_directory:
            oversized = Path(temporary_directory) / "oversized.exe"
            oversized.write_bytes(b"12")
            with mock.patch.object(verify_windows_signatures, "MAX_TOOL_BYTES", 1):
                with self.assertRaisesRegex(
                    WindowsSignatureVerificationError,
                    "unavailable or untrusted",
                ):
                    verify_windows_signatures._resolve_tool(
                        oversized,
                        error_code="signtool_unavailable",
                    )
                with self.assertRaisesRegex(
                    WindowsSignatureVerificationError,
                    "could not run",
                ):
                    verify_windows_signatures._tool_sha256(oversized)

    def test_native_environment_excludes_unrelated_secrets(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"QUOTABOT_TEST_SECRET": "must-not-pass"},
            clear=False,
        ):
            environment = verify_windows_signatures._native_environment(
                Path("candidate.exe")
            )
        self.assertNotIn("QUOTABOT_TEST_SECRET", environment)
        self.assertNotIn("PSModulePath", environment)
        self.assertNotIn("PATH", environment)
        self.assertNotIn("PATHEXT", environment)
        self.assertEqual(environment["QUOTABOT_SIGNATURE_TARGET"], "candidate.exe")

    def test_native_tool_runs_from_its_own_directory(self) -> None:
        executable = Path(sys.executable).resolve()
        completed = verify_windows_signatures._run_native(
            [str(executable), "-c", "import os; print(os.getcwd())"],
            target=Path("candidate") / "quotabot.exe",
            deadline=time.monotonic() + 10,
        )
        self.assertEqual(
            Path(completed.stdout.decode().strip()).resolve(), executable.parent
        )

    def test_verifier_maps_structured_failure_states_without_raw_output(
        self,
    ) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=VALID_SIGNTOOL_OUTPUT,
            stderr=b"",
        )
        base = AuthenticodeMetadata(
            status="Valid",
            signature_type="Authenticode",
            signer_subject="CN=Expected",
            signer_thumbprint="A" * 40,
            timestamp_subject="CN=Timestamp",
            timestamp_thumbprint="B" * 40,
        )
        cases = (
            (
                AuthenticodeMetadata(**{**base.__dict__, "status": "NotSigned"}),
                completed,
                "signature_missing",
            ),
            (
                AuthenticodeMetadata(**{**base.__dict__, "status": "HashMismatch"}),
                completed,
                "signature_invalid",
            ),
            (
                AuthenticodeMetadata(**{**base.__dict__, "signature_type": "Catalog"}),
                completed,
                "signature_type_invalid",
            ),
            (
                AuthenticodeMetadata(**{**base.__dict__, "signer_subject": "CN=Other"}),
                completed,
                "signer_mismatch",
            ),
            (
                AuthenticodeMetadata(**{**base.__dict__, "timestamp_subject": None}),
                completed,
                "timestamp_missing",
            ),
            (
                AuthenticodeMetadata(**{**base.__dict__, "signer_subject": None}),
                completed,
                "signer_metadata_invalid",
            ),
            (
                base,
                subprocess.CompletedProcess(
                    args=[], returncode=2, stdout=b"warning", stderr=b""
                ),
                "native_tool_warning",
            ),
            (
                base,
                subprocess.CompletedProcess(
                    args=[], returncode=1, stdout=b"failed", stderr=b""
                ),
                "signature_invalid",
            ),
        )
        for metadata, native_result, code in cases:
            with self.subTest(code=code):
                with (
                    mock.patch.object(
                        verify_windows_signatures,
                        "_run_native",
                        return_value=native_result,
                    ),
                    mock.patch.object(
                        verify_windows_signatures,
                        "_read_authenticode_metadata",
                        return_value=metadata,
                    ),
                ):
                    with self.assertRaises(WindowsSignatureVerificationError) as caught:
                        verify_windows_signatures._verify_pe(
                            Path("hidden.exe"),
                            relative_path="bin/quotabot.exe",
                            sha256="c" * 64,
                            expected_subject="CN=Expected",
                            expected_thumbprint="A" * 40,
                            signtool_path=Path("signtool.exe"),
                            powershell_path=Path("powershell.exe"),
                            deadline=time.monotonic() + 10,
                        )
                self.assertEqual(caught.exception.code, code)
                self.assertEqual(
                    caught.exception.relative_path,
                    "bin/quotabot.exe",
                )

    def test_native_timeout_and_output_limits_fail_closed(self) -> None:
        executable = str(Path(sys.executable).resolve())
        with mock.patch.object(
            verify_windows_signatures,
            "NATIVE_COMMAND_TIMEOUT_SECONDS",
            0.05,
        ):
            with self.assertRaisesRegex(
                WindowsSignatureVerificationError,
                "timed out",
            ):
                verify_windows_signatures._run_native(
                    [executable, "-c", "import time; time.sleep(5)"],
                    target=Path("candidate.exe"),
                    deadline=time.monotonic() + 10,
                )

        with mock.patch.object(
            verify_windows_signatures,
            "MAX_NATIVE_OUTPUT_BYTES",
            4,
        ):
            with self.assertRaisesRegex(
                WindowsSignatureVerificationError,
                "output exceeded",
            ):
                verify_windows_signatures._run_native(
                    [executable, "-c", "print('12345', end='')"],
                    target=Path("candidate.exe"),
                    deadline=time.monotonic() + 10,
                )

    def test_structured_metadata_rejects_non_string_values(self) -> None:
        payload = {
            "status": "Valid",
            "signature_type": "Authenticode",
            "signer_subject": "CN=Expected",
            "signer_thumbprint": [],
            "timestamp_subject": "CN=Timestamp",
            "timestamp_thumbprint": "B" * 40,
        }
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(payload).encode(),
            stderr=b"",
        )
        with mock.patch.object(
            verify_windows_signatures,
            "_run_native",
            return_value=completed,
        ):
            with self.assertRaisesRegex(
                WindowsSignatureVerificationError,
                "metadata is incomplete or invalid",
            ):
                verify_windows_signatures._read_authenticode_metadata(
                    Path("hidden.exe"),
                    powershell_path=Path("powershell.exe"),
                    deadline=time.monotonic() + 10,
                )

        invalid_results = (
            subprocess.CompletedProcess(args=[], returncode=1, stdout=b"", stderr=b""),
            subprocess.CompletedProcess(
                args=[], returncode=0, stdout=b"[]", stderr=b""
            ),
        )
        for native_result in invalid_results:
            with (
                self.subTest(returncode=native_result.returncode),
                mock.patch.object(
                    verify_windows_signatures,
                    "_run_native",
                    return_value=native_result,
                ),
                self.assertRaises(WindowsSignatureVerificationError) as caught,
            ):
                verify_windows_signatures._read_authenticode_metadata(
                    Path("hidden.exe"),
                    powershell_path=Path("powershell.exe"),
                    deadline=time.monotonic() + 10,
                )
            self.assertIn(
                caught.exception.code,
                {"native_tool_failed", "signer_metadata_invalid"},
            )

    def test_timestamp_parser_failure_has_bounded_relative_path(self) -> None:
        metadata = AuthenticodeMetadata(
            status="Valid",
            signature_type="Authenticode",
            signer_subject="CN=Expected",
            signer_thumbprint="A" * 40,
            timestamp_subject="CN=Timestamp",
            timestamp_thumbprint="B" * 40,
        )
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=VALID_SIGNTOOL_OUTPUT,
            stderr=b"",
        )
        with (
            mock.patch.object(
                verify_windows_signatures,
                "_run_native",
                return_value=completed,
            ),
            mock.patch.object(
                verify_windows_signatures,
                "_read_authenticode_metadata",
                return_value=metadata,
            ),
            mock.patch.object(
                verify_windows_signatures,
                "_read_timestamp_message_imprint",
                side_effect=WindowsSignatureVerificationError(
                    "timestamp_policy_unproven"
                ),
            ),
            self.assertRaises(WindowsSignatureVerificationError) as caught,
        ):
            verify_windows_signatures._verify_pe(
                Path("private-root") / "signed.exe",
                relative_path="bin/quotabot.exe",
                sha256="c" * 64,
                expected_subject="CN=Expected",
                expected_thumbprint="A" * 40,
                signtool_path=Path("signtool.exe"),
                powershell_path=Path("powershell.exe"),
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(caught.exception.code, "timestamp_policy_unproven")
        self.assertEqual(caught.exception.relative_path, "bin/quotabot.exe")
        self.assertNotIn("private-root", str(caught.exception))

    def test_json_mode_bounds_unexpected_native_failure(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(
                verify_windows_signatures,
                "verify_windows_signatures",
                side_effect=OSError("private native detail"),
            ),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            result = verify_windows_signatures.main(
                [
                    "--manifest",
                    "manifest.json",
                    "--surface",
                    "cli",
                    "--architecture",
                    "x64",
                    "--expected-signer-subject",
                    "CN=Expected",
                    "--expected-signer-thumbprint",
                    "A" * 40,
                    "--json",
                    "candidate",
                ]
            )
        self.assertEqual(result, 1)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(
            payload,
            {
                "schema": "quotabot.windows-signature-verification-error.v1",
                "verified": False,
                "error_code": "native_tool_failed",
                "message": "native signature verification could not run",
            },
        )
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn("private native detail", stdout.getvalue())


@unittest.skipUnless(os.name == "nt", "native Authenticode tests require Windows")
class NativeWindowsSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.signtool = verify_windows_signatures.find_signtool()
        cls.powershell = verify_windows_signatures.find_powershell()
        located_pwsh = shutil.which("pwsh.exe")
        fallback = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / (
            "PowerShell/7/pwsh.exe"
        )
        cls.signed_binary = Path(located_pwsh) if located_pwsh else fallback
        if not cls.signed_binary.is_file():
            raise AssertionError("signed PowerShell fixture is unavailable")

    def _candidate(
        self,
        base: Path,
        *,
        two_files: bool = False,
        corrupt: bool = False,
    ) -> tuple[Path, Path, AuthenticodeMetadata]:
        root = base / "candidate"
        launcher = root / "bin" / "quotabot.exe"
        launcher.parent.mkdir(parents=True)
        shutil.copy2(self.signed_binary, launcher)
        if two_files:
            plugin = root / "lib" / "plugin.bin"
            plugin.parent.mkdir(parents=True)
            shutil.copy2(self.signed_binary, plugin)
        if corrupt:
            with launcher.open("r+b") as handle:
                handle.seek(4096)
                original = handle.read(1)
                handle.seek(4096)
                handle.write(bytes([original[0] ^ 0x01]))
        manifest = base / "manifest.json"
        _write_manifest(root, manifest)
        metadata = verify_windows_signatures._read_authenticode_metadata(
            launcher,
            powershell_path=self.powershell,
            deadline=time.monotonic() + 30,
        )
        return root, manifest, metadata

    def test_real_embedded_signature_produces_deterministic_bounded_receipt(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, metadata = self._candidate(base, two_files=True)
            self.assertEqual(metadata.status, "Valid")
            self.assertEqual(metadata.signature_type, "Authenticode")
            self.assertIsNotNone(metadata.timestamp_subject)

            first = verify_windows_signatures.verify_windows_signatures(
                root,
                manifest_path=manifest,
                surface="cli",
                architecture="x64",
                expected_signer_subject=metadata.signer_subject or "",
                expected_signer_thumbprint=metadata.signer_thumbprint or "",
            )
            repeated = verify_windows_signatures.verify_windows_signatures(
                root,
                manifest_path=manifest,
                surface="cli",
                architecture="x64",
                expected_signer_subject=metadata.signer_subject or "",
                expected_signer_thumbprint=metadata.signer_thumbprint or "",
            )

            self.assertEqual(first.to_dict(), repeated.to_dict())
            self.assertEqual(first.native_code_count, 2)
            self.assertTrue(first.to_dict()["candidate_stable"])
            self.assertRegex(first.verification_sha256, r"^[0-9a-f]{64}$")
            self.assertRegex(first.signtool_sha256, r"^[0-9a-f]{64}$")
            self.assertRegex(first.powershell_sha256, r"^[0-9a-f]{64}$")
            for signature in first.signatures:
                self.assertEqual(
                    signature.timestamp_message_imprint_algorithm,
                    "sha256",
                )
                self.assertRegex(
                    signature.timestamp_message_imprint,
                    r"^[0-9a-f]{64}$",
                )
            serialized = json.dumps(first.to_dict())
            self.assertNotIn(str(base), serialized)
            self.assertNotIn(str(self.signtool), serialized)
            self.assertNotIn("generated_at", serialized)

    def test_wrong_signer_and_corrupted_signature_fail_with_exact_codes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, metadata = self._candidate(base)
            with self.assertRaises(WindowsSignatureVerificationError) as wrong:
                verify_windows_signatures.verify_windows_signatures(
                    root,
                    manifest_path=manifest,
                    surface="cli",
                    architecture="x64",
                    expected_signer_subject=metadata.signer_subject or "",
                    expected_signer_thumbprint="0" * 40,
                )
            self.assertEqual(wrong.exception.code, "signer_mismatch")

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, metadata = self._candidate(base, corrupt=True)
            with self.assertRaises(WindowsSignatureVerificationError) as corrupted:
                verify_windows_signatures.verify_windows_signatures(
                    root,
                    manifest_path=manifest,
                    surface="cli",
                    architecture="x64",
                    expected_signer_subject=metadata.signer_subject or "CN=Expected",
                    expected_signer_thumbprint=(metadata.signer_thumbprint or "A" * 40),
                )
            self.assertEqual(corrupted.exception.code, "signature_invalid")

    def test_manifest_mismatch_and_during_verification_mutation_fail(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, metadata = self._candidate(base)
            (root / "notice.txt").write_text("added", encoding="utf-8")
            with self.assertRaises(WindowsSignatureVerificationError) as mismatch:
                verify_windows_signatures.verify_windows_signatures(
                    root,
                    manifest_path=manifest,
                    surface="cli",
                    architecture="x64",
                    expected_signer_subject=metadata.signer_subject or "",
                    expected_signer_thumbprint=metadata.signer_thumbprint or "",
                )
            self.assertEqual(mismatch.exception.code, "inventory_mismatch")

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "candidate"
            launcher = root / "bin" / "quotabot.exe"
            launcher.parent.mkdir(parents=True)
            shutil.copy2(self.signed_binary, launcher)
            notice = root / "notice.txt"
            notice.write_text("before", encoding="utf-8")
            manifest = base / "manifest.json"
            _write_manifest(root, manifest)
            metadata = verify_windows_signatures._read_authenticode_metadata(
                launcher,
                powershell_path=self.powershell,
                deadline=time.monotonic() + 30,
            )
            real_verify = verify_windows_signatures._verify_pe

            def mutate_after_verify(*args, **kwargs):
                result = real_verify(*args, **kwargs)
                notice.write_text("after", encoding="utf-8")
                return result

            with mock.patch.object(
                verify_windows_signatures,
                "_verify_pe",
                side_effect=mutate_after_verify,
            ):
                with self.assertRaises(WindowsSignatureVerificationError) as changed:
                    verify_windows_signatures.verify_windows_signatures(
                        root,
                        manifest_path=manifest,
                        surface="cli",
                        architecture="x64",
                        expected_signer_subject=metadata.signer_subject or "",
                        expected_signer_thumbprint=metadata.signer_thumbprint or "",
                    )
            self.assertEqual(changed.exception.code, "candidate_changed")

    def test_cli_failure_is_path_private_and_success_is_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, metadata = self._candidate(base)
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                failed = verify_windows_signatures.main(
                    [
                        "--manifest",
                        str(manifest),
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        "--expected-signer-subject",
                        metadata.signer_subject or "",
                        "--expected-signer-thumbprint",
                        "0" * 40,
                        str(root),
                    ]
                )
            self.assertEqual(failed, 1)
            self.assertIn("[signer_mismatch]", stderr.getvalue())
            self.assertIn("bin/quotabot.exe", stderr.getvalue())
            self.assertNotIn(str(base), stderr.getvalue())

            json_stdout = io.StringIO()
            json_stderr = io.StringIO()
            with redirect_stdout(json_stdout), redirect_stderr(json_stderr):
                failed_json = verify_windows_signatures.main(
                    [
                        "--manifest",
                        str(manifest),
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        "--expected-signer-subject",
                        metadata.signer_subject or "",
                        "--expected-signer-thumbprint",
                        "0" * 40,
                        "--json",
                        str(root),
                    ]
                )
            self.assertEqual(failed_json, 1)
            failure_payload = json.loads(json_stdout.getvalue())
            self.assertEqual(
                failure_payload["schema"],
                "quotabot.windows-signature-verification-error.v1",
            )
            self.assertFalse(failure_payload["verified"])
            self.assertEqual(failure_payload["error_code"], "signer_mismatch")
            self.assertEqual(failure_payload["path"], "bin/quotabot.exe")
            self.assertEqual(json_stderr.getvalue(), "")
            self.assertNotIn(str(base), json_stdout.getvalue())

            stdout = io.StringIO()
            with redirect_stdout(stdout):
                passed = verify_windows_signatures.main(
                    [
                        "--manifest",
                        str(manifest),
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        "--expected-signer-subject",
                        metadata.signer_subject or "",
                        "--expected-signer-thumbprint",
                        metadata.signer_thumbprint or "",
                        "--json",
                        str(root),
                    ]
                )
            self.assertEqual(passed, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(
                payload["schema"],
                "quotabot.windows-signature-verification.v1",
            )
            self.assertTrue(payload["verified"])
            self.assertNotIn(str(base), stdout.getvalue())

            human_stdout = io.StringIO()
            with redirect_stdout(human_stdout):
                human_passed = verify_windows_signatures.main(
                    [
                        "--manifest",
                        str(manifest),
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        "--expected-signer-subject",
                        metadata.signer_subject or "",
                        "--expected-signer-thumbprint",
                        metadata.signer_thumbprint or "",
                        str(root),
                    ]
                )
            self.assertEqual(human_passed, 0)
            self.assertIn(
                "Windows signature policy verified cli/x64", human_stdout.getvalue()
            )
            self.assertIn("authenticode file-sha256=", human_stdout.getvalue())
            self.assertIn("timestamp-protocol=rfc3161", human_stdout.getvalue())
            self.assertIn(
                "timestamp-message-imprint-sha256=",
                human_stdout.getvalue(),
            )
            self.assertNotIn(str(base), human_stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
