"""Tests for bounded Windows Authenticode policy verification."""

from __future__ import annotations

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
from tools import verify_windows_signatures
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


def _pe() -> bytes:
    payload = bytearray(512)
    payload[0:2] = b"MZ"
    struct.pack_into("<I", payload, 0x3C, 0x80)
    payload[0x80:0x84] = b"PE\x00\x00"
    struct.pack_into("<HHIIIHH", payload, 0x84, 0x8664, 1, 0, 0, 0, 0xF0, 0x2022)
    struct.pack_into("<H", payload, 0x98, 0x20B)
    struct.pack_into("<II", payload, 0xD0, 4096, 512)
    return bytes(payload)


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
                base,
                subprocess.CompletedProcess(
                    args=[], returncode=2, stdout=b"warning", stderr=b""
                ),
                "native_tool_warning",
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
            self.assertIn("authenticode sha256 rfc3161", human_stdout.getvalue())
            self.assertNotIn(str(base), human_stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
