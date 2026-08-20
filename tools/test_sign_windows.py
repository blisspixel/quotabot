"""Tests for fail-closed Windows Authenticode signing."""

from __future__ import annotations

import base64
import io
import json
import os
import struct
import tempfile
import unittest
import unittest.mock as mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tools import sign_windows
from tools.sign_windows import WindowsSignError


def _pe() -> bytes:
    payload = bytearray(512)
    payload[0:2] = b"MZ"
    struct.pack_into("<I", payload, 0x3C, 0x80)
    payload[0x80:0x84] = b"PE\x00\x00"
    struct.pack_into("<HHIIIHH", payload, 0x84, 0x8664, 1, 0, 0, 0, 0xF0, 0x2022)
    struct.pack_into("<H", payload, 0x98, 0x20B)
    struct.pack_into("<II", payload, 0xD0, 4096, 512)
    return bytes(payload)


def _manifest(
    directory: Path,
    *,
    relative: str = "bin/quotabot.exe",
    surface: str = "cli",
    architecture: str = "x64",
    extra: dict[str, object] | None = None,
) -> Path:
    payload = {
        "schema": "quotabot.signing-inventory.v1",
        "platform": "windows",
        "surface": surface,
        "architecture": architecture,
        "native_code": [{"path": relative}],
    }
    if extra:
        payload.update(extra)
    path = directory / "unsigned-inventory.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def _clear_signing_env() -> None:
    for name in (
        "QUOTABOT_WINDOWS_PFX_BASE64",
        "QUOTABOT_WINDOWS_PFX_PASSWORD",
        "QUOTABOT_WINDOWS_TIMESTAMP_URL",
    ):
        os.environ.pop(name, None)


class SignWindowsTests(unittest.TestCase):
    def setUp(self) -> None:
        self._saved = {
            name: os.environ.get(name)
            for name in (
                "QUOTABOT_WINDOWS_PFX_BASE64",
                "QUOTABOT_WINDOWS_PFX_PASSWORD",
                "QUOTABOT_WINDOWS_TIMESTAMP_URL",
            )
        }
        _clear_signing_env()

    def tearDown(self) -> None:
        _clear_signing_env()
        for name, value in self._saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def test_missing_secrets_fail_closed(self) -> None:
        with self.assertRaises(WindowsSignError) as raised:
            sign_windows._required_env("QUOTABOT_WINDOWS_PFX_BASE64")
        self.assertEqual(raised.exception.code, "missing_signing_secret")
        self.assertNotIn("PFX", str(raised.exception))
        self.assertNotIn("PASSWORD", str(raised.exception))

    def test_timestamp_url_rejects_credentials_and_loopback(self) -> None:
        for url in (
            "",
            "not-a-url",
            "file:///tmp/stamp",
            "http://user:pass@timestamp.example",
            "http://localhost/stamp",
            "https://127.0.0.1/stamp",
            "http://timestamp.example?token=1",
            "http://timestamp.example#frag",
        ):
            with self.subTest(url=url):
                with self.assertRaises(WindowsSignError) as raised:
                    sign_windows.validate_timestamp_url(url)
                self.assertEqual(raised.exception.code, "invalid_timestamp_url")

        self.assertEqual(
            sign_windows.validate_timestamp_url("http://timestamp.digicert.com"),
            "http://timestamp.digicert.com",
        )

    def test_pfx_decode_rejects_garbage_and_oversize(self) -> None:
        with self.assertRaises(WindowsSignError) as raised:
            sign_windows._decode_pfx("not-base64")
        self.assertEqual(raised.exception.code, "invalid_pfx")
        huge = base64.b64encode(b"x" * (sign_windows.MAX_PFX_BYTES + 1)).decode("ascii")
        with self.assertRaises(WindowsSignError) as raised:
            sign_windows._decode_pfx(huge)
        self.assertEqual(raised.exception.code, "invalid_pfx")
        self.assertEqual(
            sign_windows._decode_pfx(base64.b64encode(b"pkcs").decode()), b"pkcs"
        )

    def test_sign_command_uses_sha256_digest_and_rfc3161_timestamp(self) -> None:
        command = sign_windows.sign_command(
            Path("signtool.exe"),
            Path("cert.pfx"),
            "secret-password",
            "http://timestamp.digicert.com",
            Path("quotabot.exe"),
        )
        self.assertEqual(
            command[1:7],
            [
                "sign",
                "/fd",
                "SHA256",
                "/tr",
                "http://timestamp.digicert.com",
                "/td",
            ],
        )
        self.assertEqual(command[7], "SHA256")
        self.assertLess(command.index("/tr"), command.index("/td"))
        self.assertIn("/f", command)
        self.assertIn("/p", command)
        self.assertEqual(command[command.index("/p") + 1], "secret-password")

    def test_redact_secret_strips_password_and_pfx_material(self) -> None:
        text = "signtool /p super-secret /f MIIB"
        redacted = sign_windows.redact_secret(
            sign_windows.redact_secret(text, "super-secret"),
            "MIIB",
        )
        self.assertNotIn("super-secret", redacted)
        self.assertNotIn("MIIB", redacted)
        self.assertIn("[redacted]", redacted)

    def test_inventory_rejects_path_escape_and_empty_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "bin" / "quotabot.exe").write_bytes(b"MZ")
            escaped = _manifest(root, relative="../secrets.pfx")
            with self.assertRaises(WindowsSignError) as raised:
                sign_windows._inventory_targets(
                    escaped,
                    root,
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "path_outside_candidate")

            empty = _manifest(root, extra={"native_code": []})
            with self.assertRaises(WindowsSignError) as raised:
                sign_windows._inventory_targets(
                    empty,
                    root,
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "native_code_empty")

    def test_inventory_requires_matching_surface(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "quotabot.exe").write_bytes(b"MZ")
            manifest = _manifest(
                root,
                relative="quotabot.exe",
                surface="desktop",
            )
            with self.assertRaises(WindowsSignError) as raised:
                sign_windows._inventory_targets(
                    manifest,
                    root,
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "inventory_invalid")

    def test_current_candidate_must_equal_complete_unsigned_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "candidate"
            launcher = root / "bin" / "quotabot.exe"
            launcher.parent.mkdir(parents=True)
            launcher.write_bytes(_pe())
            notice = root / "lib" / "notice.txt"
            notice.parent.mkdir()
            notice.write_text("original\n", encoding="utf-8")
            expected = sign_windows.inventory_native_code(
                root,
                platform="windows",
                surface="cli",
                architecture="x64",
            ).to_dict()
            manifest = Path(directory) / "unsigned-inventory.json"
            manifest.write_text(json.dumps(expected), encoding="utf-8")

            self.assertEqual(
                sign_windows._require_current_inventory(
                    manifest,
                    root,
                    surface="cli",
                    architecture="x64",
                ),
                expected,
            )

            notice.write_text("changed\n", encoding="utf-8")
            with self.assertRaises(WindowsSignError) as raised:
                sign_windows._require_current_inventory(
                    manifest,
                    root,
                    surface="cli",
                    architecture="x64",
                )
            self.assertEqual(raised.exception.code, "candidate_changed")

    def test_main_missing_secret_prints_bounded_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "bin" / "quotabot.exe").write_bytes(b"MZ")
            manifest = _manifest(root)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                status = sign_windows.main(
                    [
                        "--manifest",
                        str(manifest),
                        "--surface",
                        "cli",
                        "--architecture",
                        "x64",
                        str(root),
                    ]
                )
            self.assertEqual(status, 1)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["schema"], "quotabot.windows-sign-error.v1")
            self.assertEqual(payload["ok"], False)
            if os.name == "nt":
                self.assertEqual(payload["code"], "missing_signing_secret")
            else:
                self.assertEqual(payload["code"], "unsupported_platform")
            self.assertNotIn("PASSWORD", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

    def test_source_never_prints_secret_environment_values(self) -> None:
        source = Path(sign_windows.__file__).read_text(encoding="utf-8")
        self.assertNotIn("print(password)", source)
        self.assertNotIn("print(pfx_b64)", source)
        self.assertNotIn("Write-Host", source)
        self.assertIn("redact_secret", source)
        self.assertIn("/fd", source)
        self.assertIn("SHA256", source)

    def test_successful_sign_invokes_signtool_per_pe(self) -> None:
        if os.name != "nt":
            self.skipTest("Windows Authenticode signing requires Windows")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "bin" / "quotabot.exe"
            second = root / "lib" / "sqlite3.dll"
            first.parent.mkdir()
            second.parent.mkdir()
            first.write_bytes(b"MZ")
            second.write_bytes(b"MZ")
            manifest = root / "unsigned-inventory.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schema": "quotabot.signing-inventory.v1",
                        "platform": "windows",
                        "surface": "cli",
                        "architecture": "x64",
                        "native_code": [
                            {"path": "bin/quotabot.exe"},
                            {"path": "lib/sqlite3.dll"},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            os.environ["QUOTABOT_WINDOWS_PFX_BASE64"] = base64.b64encode(
                b"pkcs"
            ).decode()
            os.environ["QUOTABOT_WINDOWS_PFX_PASSWORD"] = "unit-test-password"
            os.environ["QUOTABOT_WINDOWS_TIMESTAMP_URL"] = "http://timestamp.example"
            commands: list[list[str]] = []

            def fake_run(command, **_kwargs):
                commands.append(list(command))
                return mock.Mock(returncode=0, stdout=b"Successfully signed")

            with (
                mock.patch.object(
                    sign_windows,
                    "_require_current_inventory",
                    return_value=json.loads(manifest.read_text(encoding="utf-8")),
                ),
                mock.patch.object(
                    sign_windows,
                    "find_signtool",
                    return_value=Path("C:/kits/signtool.exe"),
                ),
                mock.patch.object(sign_windows.subprocess, "run", side_effect=fake_run),
            ):
                stdout = io.StringIO()
                with redirect_stdout(stdout):
                    status = sign_windows.main(
                        [
                            "--manifest",
                            str(manifest),
                            "--surface",
                            "cli",
                            "--architecture",
                            "x64",
                            str(root),
                        ]
                    )
            self.assertEqual(status, 0)
            self.assertEqual(len(commands), 2)
            self.assertEqual(
                json.loads(stdout.getvalue())["schema"], "quotabot.windows-sign.v1"
            )
            for command in commands:
                self.assertIn("/fd", command)
                self.assertIn("SHA256", command)
                self.assertIn("/tr", command)
                self.assertNotIn(str(root / "unsigned-inventory.json"), command)


if __name__ == "__main__":
    unittest.main()
