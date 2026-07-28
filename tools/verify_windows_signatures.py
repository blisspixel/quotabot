#!/usr/bin/env python3
"""Verify every PE in an exact post-signing inventory with Windows policy."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.native_code_inventory import (  # noqa: E402
    NativeInventoryError,
    canonical_sha256,
    inventory_native_code,
    load_inventory_manifest,
)
from tools.windows_timestamp_policy import (  # noqa: E402
    TimestampMessageImprint,
    TimestampPolicyError,
    read_timestamp_message_imprint,
)


SCHEMA = "quotabot.windows-signature-verification.v1"
ERROR_SCHEMA = "quotabot.windows-signature-verification-error.v1"
MAX_NATIVE_OUTPUT_BYTES = 64 * 1024
MAX_TOOL_BYTES = 100 * 1024 * 1024
MAX_RECEIPT_BYTES = 16 * 1024 * 1024
MAX_SIGNER_SUBJECT_CHARS = 512
NATIVE_COMMAND_TIMEOUT_SECONDS = 30.0
VERIFICATION_TIMEOUT_SECONDS = 300.0

_THUMBPRINT = re.compile(r"^[0-9A-F]{40}$")
_SIGNATURE_ROW = re.compile(
    r"^[ \t]*(?P<index>\d+)[ \t]+(?P<algorithm>[A-Za-z0-9_-]+)"
    r"[ \t]+(?P<timestamp>[A-Za-z0-9_-]+)[ \t]*\r?$",
    re.MULTILINE,
)

_ERROR_MESSAGES = {
    "unsupported_platform": "Windows signature verification requires Windows",
    "invalid_expected_signer": "expected signer policy is invalid",
    "inventory_invalid": "post-signing inventory cannot be validated",
    "inventory_mismatch": "candidate does not match the post-signing inventory",
    "signtool_unavailable": "SignTool is unavailable or untrusted",
    "powershell_unavailable": "PowerShell signature inspection is unavailable",
    "native_tool_timeout": "native signature verification timed out",
    "native_output_oversized": "native signature verification output exceeded its limit",
    "native_tool_failed": "native signature verification could not run",
    "native_tool_warning": "native signature verification returned a warning",
    "signature_missing": "an inventoried PE has no embedded Authenticode signature",
    "signature_invalid": "an inventoried PE has an invalid Authenticode signature",
    "signature_type_invalid": "an inventoried PE does not use an embedded Authenticode signature",
    "signer_metadata_invalid": "signature identity metadata is incomplete or invalid",
    "signer_mismatch": "signature does not match the expected publisher identity",
    "timestamp_missing": "signature has no trusted timestamp",
    "signature_policy_unproven": "SHA-256 and RFC 3161 policy could not be proven",
    "timestamp_policy_unproven": (
        "RFC 3161 timestamp message-imprint SHA-256 policy could not be proven"
    ),
    "candidate_changed": "candidate changed during signature verification",
    "receipt_output_invalid": "receipt output could not be published safely",
}

_ERROR_STAGES = {
    "unsupported_platform": "preflight",
    "invalid_expected_signer": "preflight",
    "inventory_invalid": "inventory",
    "inventory_mismatch": "inventory",
    "signtool_unavailable": "native_tool_resolution",
    "powershell_unavailable": "native_tool_resolution",
    "native_tool_timeout": "native_verification",
    "native_output_oversized": "native_verification",
    "native_tool_failed": "native_verification",
    "native_tool_warning": "authenticode",
    "signature_missing": "authenticode",
    "signature_invalid": "authenticode",
    "signature_type_invalid": "authenticode",
    "signer_metadata_invalid": "authenticode",
    "signer_mismatch": "authenticode",
    "timestamp_missing": "timestamp",
    "signature_policy_unproven": "signature_policy",
    "timestamp_policy_unproven": "timestamp_policy",
    "candidate_changed": "stability",
    "receipt_output_invalid": "receipt_output",
}


class WindowsSignatureVerificationError(ValueError):
    """A bounded, path-safe verification failure."""

    def __init__(self, code: str, relative_path: str | None = None):
        if code not in _ERROR_MESSAGES:
            raise ValueError(f"unknown verification error code: {code}")
        self.code = code
        self.relative_path = relative_path
        super().__init__(code)

    def __str__(self) -> str:
        message = _ERROR_MESSAGES[self.code]
        if self.relative_path is not None:
            return f"{message}: {self.relative_path}"
        return message


def _failure_payload(
    error: WindowsSignatureVerificationError,
    *,
    surface: str,
    architecture: str,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "schema": ERROR_SCHEMA,
        "verified": False,
        "surface": surface,
        "architecture": architecture,
        "stage": _ERROR_STAGES[error.code],
        "error_code": error.code,
        "message": _ERROR_MESSAGES[error.code],
    }
    if error.relative_path is not None:
        payload["path"] = error.relative_path
    return payload


def _canonical_json(payload: dict[str, object]) -> str:
    return json.dumps(
        payload,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    )


@dataclass(frozen=True)
class AuthenticodeMetadata:
    status: str
    signature_type: str
    signer_subject: str | None
    signer_thumbprint: str | None
    timestamp_subject: str | None
    timestamp_thumbprint: str | None


@dataclass(frozen=True)
class VerifiedPeSignature:
    path: str
    sha256: str
    signer_subject: str
    signer_thumbprint: str
    timestamp_subject: str
    timestamp_thumbprint: str
    timestamp_message_imprint_algorithm: str
    timestamp_message_imprint: str

    def to_dict(self) -> dict[str, object]:
        return {
            "path": self.path,
            "sha256": self.sha256,
            "authenticode_valid": True,
            "expected_signer_matched": True,
            "file_digest_algorithm": "sha256",
            "timestamp_present": True,
            "timestamp_protocol": "rfc3161",
            "timestamp_message_imprint_algorithm": (
                self.timestamp_message_imprint_algorithm
            ),
            "timestamp_message_imprint": self.timestamp_message_imprint,
            "signer_subject": self.signer_subject,
            "signer_thumbprint": self.signer_thumbprint,
            "timestamp_subject": self.timestamp_subject,
            "timestamp_thumbprint": self.timestamp_thumbprint,
        }


@dataclass(frozen=True)
class WindowsSignatureReceipt:
    schema: str
    surface: str
    architecture: str
    candidate_sha256: str
    inventory_sha256: str
    signtool_sha256: str
    powershell_sha256: str
    expected_signer_subject: str
    expected_signer_thumbprint: str
    signatures: tuple[VerifiedPeSignature, ...]
    verification_sha256: str

    @property
    def native_code_count(self) -> int:
        return len(self.signatures)

    def to_dict(self) -> dict[str, object]:
        return {
            "schema": self.schema,
            "surface": self.surface,
            "architecture": self.architecture,
            "candidate_sha256": self.candidate_sha256,
            "inventory_sha256": self.inventory_sha256,
            "signtool_sha256": self.signtool_sha256,
            "powershell_sha256": self.powershell_sha256,
            "expected_signer_subject": self.expected_signer_subject,
            "expected_signer_thumbprint": self.expected_signer_thumbprint,
            "native_code_count": self.native_code_count,
            "signatures": [item.to_dict() for item in self.signatures],
            "candidate_stable": True,
            "verified": True,
            "verification_sha256": self.verification_sha256,
        }


def _normalize_thumbprint(value: str) -> str:
    normalized = "".join(value.split()).upper()
    if not _THUMBPRINT.fullmatch(normalized):
        raise WindowsSignatureVerificationError("invalid_expected_signer")
    return normalized


def _validate_subject(value: str) -> str:
    if (
        not value
        or len(value) > MAX_SIGNER_SUBJECT_CHARS
        or value != value.strip()
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise WindowsSignatureVerificationError("invalid_expected_signer")
    return value


def _is_junction(path: Path) -> bool:
    predicate = getattr(path, "is_junction", None)
    return bool(predicate is not None and predicate())


def _validated_receipt_path(
    path: Path,
    *,
    candidate_root: Path,
    manifest_path: Path,
) -> Path:
    requested = Path(path)
    try:
        name = requested.name
        if (
            not name
            or name != name.rstrip(" .")
            or ":" in name
            or requested.is_symlink()
            or _is_junction(requested)
        ):
            raise WindowsSignatureVerificationError("receipt_output_invalid")
        parent = requested.parent.resolve(strict=True)
        if not parent.is_dir():
            raise WindowsSignatureVerificationError("receipt_output_invalid")
        resolved = parent / name
        if resolved.exists() and not resolved.is_file():
            raise WindowsSignatureVerificationError("receipt_output_invalid")
        candidate = Path(candidate_root).resolve(strict=False)
        manifest = Path(manifest_path).resolve(strict=False)
        if (
            resolved.exists()
            and manifest.exists()
            and os.path.samefile(resolved, manifest)
        ):
            raise WindowsSignatureVerificationError("receipt_output_invalid")
    except WindowsSignatureVerificationError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise WindowsSignatureVerificationError("receipt_output_invalid") from error
    if (
        resolved == manifest
        or resolved == candidate
        or resolved.is_relative_to(candidate)
    ):
        raise WindowsSignatureVerificationError("receipt_output_invalid")
    return resolved


def _write_json_receipt(path: Path, payload: dict[str, object]) -> None:
    encoded = (_canonical_json(payload) + "\n").encode("utf-8")
    if len(encoded) > MAX_RECEIPT_BYTES:
        raise WindowsSignatureVerificationError("receipt_output_invalid")
    temporary: Path | None = None
    descriptor = -1
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    except (OSError, RuntimeError, ValueError) as error:
        raise WindowsSignatureVerificationError("receipt_output_invalid") from error
    finally:
        if descriptor >= 0:
            with suppress(OSError):
                os.close(descriptor)
        if temporary is not None:
            with suppress(OSError):
                temporary.unlink()


def _publish_json_payload(
    payload: dict[str, object],
    *,
    receipt_path: Path | None,
    surface: str,
    architecture: str,
) -> bool:
    if receipt_path is None:
        print(_canonical_json(payload))
        return True
    try:
        _write_json_receipt(receipt_path, payload)
    except WindowsSignatureVerificationError as error:
        print(
            _canonical_json(
                _failure_payload(
                    error,
                    surface=surface,
                    architecture=architecture,
                )
            )
        )
        return False
    return True


def _resolve_tool(path: Path, *, error_code: str) -> Path:
    requested = Path(path)
    try:
        if requested.is_symlink() or _is_junction(requested):
            raise WindowsSignatureVerificationError(error_code)
        resolved = requested.resolve(strict=True)
        metadata = resolved.stat()
    except WindowsSignatureVerificationError:
        raise
    except (OSError, RuntimeError) as error:
        raise WindowsSignatureVerificationError(error_code) from error
    if not resolved.is_file() or metadata.st_size > MAX_TOOL_BYTES:
        raise WindowsSignatureVerificationError(error_code)
    return resolved


def _version_key(value: str) -> tuple[int, ...]:
    parts = value.split(".")
    if not parts or any(not part.isdigit() for part in parts):
        return ()
    return tuple(int(part) for part in parts)


def _windows_kits_roots() -> tuple[Path, ...]:
    import winreg

    roots: list[Path] = []
    for access in (winreg.KEY_WOW64_32KEY, winreg.KEY_WOW64_64KEY):
        try:
            with winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE,
                r"SOFTWARE\Microsoft\Windows Kits\Installed Roots",
                0,
                winreg.KEY_READ | access,
            ) as key:
                roots.append(Path(winreg.QueryValueEx(key, "KitsRoot10")[0]))
        except OSError:
            continue
    if not roots:
        program_files_x86 = os.environ.get("ProgramFiles(x86)")
        if program_files_x86:
            roots.append(Path(program_files_x86) / "Windows Kits" / "10")
    unique: list[Path] = []
    for root in roots:
        if root not in unique:
            unique.append(root)
    return tuple(unique)


def find_signtool() -> Path:
    """Resolve a fixed trusted SignTool executable without changing PATH."""
    if os.name != "nt":
        raise WindowsSignatureVerificationError("unsupported_platform")

    machine = platform.machine().casefold()
    architectures = (
        ("arm64", "x64", "x86")
        if "arm" in machine
        else (
            "x64",
            "x86",
        )
    )
    candidates: list[tuple[tuple[int, ...], int, Path]] = []
    for root in _windows_kits_roots():
        bin_root = root / "bin"
        try:
            with os.scandir(bin_root) as entries:
                versions = [entry.name for entry in entries if entry.is_dir()]
        except OSError:
            continue
        if len(versions) > 64:
            raise WindowsSignatureVerificationError("signtool_unavailable")
        for version in versions:
            version_key = _version_key(version)
            if not version_key:
                continue
            for preference, architecture in enumerate(architectures):
                candidate = bin_root / version / architecture / "signtool.exe"
                if candidate.is_file():
                    candidates.append((version_key, -preference, candidate))
    if not candidates:
        raise WindowsSignatureVerificationError("signtool_unavailable")
    return _resolve_tool(
        max(candidates, key=lambda item: (item[0], item[1]))[2],
        error_code="signtool_unavailable",
    )


def find_powershell() -> Path:
    """Resolve a fixed PowerShell executable for structured signature metadata."""
    if os.name != "nt":
        raise WindowsSignatureVerificationError("unsupported_platform")
    buffer = ctypes.create_unicode_buffer(32_768)
    try:
        length = ctypes.windll.kernel32.GetSystemDirectoryW(buffer, len(buffer))
    except (AttributeError, OSError) as error:
        raise WindowsSignatureVerificationError("powershell_unavailable") from error
    if length <= 0 or length >= len(buffer):
        raise WindowsSignatureVerificationError("powershell_unavailable")
    return _resolve_tool(
        Path(buffer.value) / "WindowsPowerShell" / "v1.0" / "powershell.exe",
        error_code="powershell_unavailable",
    )


def _tool_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        before = path.stat()
        total = 0
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_TOOL_BYTES:
                    raise WindowsSignatureVerificationError("native_tool_failed")
                digest.update(chunk)
        after = path.stat()
    except WindowsSignatureVerificationError:
        raise
    except OSError as error:
        raise WindowsSignatureVerificationError("native_tool_failed") from error
    before_identity = (before.st_size, before.st_mtime_ns, before.st_ino)
    after_identity = (after.st_size, after.st_mtime_ns, after.st_ino)
    if total != before.st_size or before_identity != after_identity:
        raise WindowsSignatureVerificationError("native_tool_failed")
    return digest.hexdigest()


def _native_environment(target: Path) -> dict[str, str]:
    allowed = (
        "SystemRoot",
        "WINDIR",
        "TEMP",
        "TMP",
        "ProgramFiles",
        "ProgramFiles(x86)",
        "ProgramData",
        "COMSPEC",
    )
    environment = {name: os.environ[name] for name in allowed if name in os.environ}
    environment["QUOTABOT_SIGNATURE_TARGET"] = str(target)
    return environment


def _remaining_timeout(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise WindowsSignatureVerificationError("native_tool_timeout")
    return min(NATIVE_COMMAND_TIMEOUT_SECONDS, remaining)


def _run_native(
    command: list[str],
    *,
    target: Path,
    deadline: float,
) -> subprocess.CompletedProcess[bytes]:
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    timeout = _remaining_timeout(deadline)
    try:
        process = subprocess.Popen(
            command,
            cwd=Path(command[0]).parent,
            env=_native_environment(target),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            creationflags=creation_flags,
        )
    except OSError as error:
        raise WindowsSignatureVerificationError("native_tool_failed") from error

    if process.stdout is None:
        process.kill()
        raise WindowsSignatureVerificationError("native_tool_failed")
    chunks: list[bytes] = []
    oversized = threading.Event()
    read_failed = threading.Event()

    def drain_output() -> None:
        total = 0
        try:
            while chunk := process.stdout.read(8192):
                total += len(chunk)
                if total > MAX_NATIVE_OUTPUT_BYTES:
                    oversized.set()
                    with suppress(OSError):
                        process.kill()
                    return
                chunks.append(chunk)
        except (OSError, ValueError):
            read_failed.set()
            with suppress(OSError):
                process.kill()

    reader = threading.Thread(target=drain_output, daemon=True)
    reader.start()
    try:
        returncode = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        with suppress(OSError):
            process.kill()
        with suppress(OSError, subprocess.TimeoutExpired):
            process.wait(timeout=5)
        reader.join(timeout=5)
        process.stdout.close()
        raise WindowsSignatureVerificationError("native_tool_timeout") from error
    reader.join(timeout=5)
    if reader.is_alive():
        with suppress(OSError):
            process.kill()
        process.stdout.close()
        raise WindowsSignatureVerificationError("native_tool_failed")
    process.stdout.close()
    if oversized.is_set():
        raise WindowsSignatureVerificationError("native_output_oversized")
    if read_failed.is_set():
        raise WindowsSignatureVerificationError("native_tool_failed")
    return subprocess.CompletedProcess(command, returncode, b"".join(chunks), b"")


def _read_authenticode_metadata(
    target: Path,
    *,
    powershell_path: Path,
    deadline: float,
) -> AuthenticodeMetadata:
    script = r"""
$ErrorActionPreference = 'Stop'
try {
  $securityModule = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
  Import-Module -Name $securityModule -Force -ErrorAction Stop
  $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $env:QUOTABOT_SIGNATURE_TARGET
  $value = [ordered]@{
    status = [string]$signature.Status
    signature_type = [string]$signature.SignatureType
    signer_subject = if ($null -eq $signature.SignerCertificate) { $null } else { $signature.SignerCertificate.Subject }
    signer_thumbprint = if ($null -eq $signature.SignerCertificate) { $null } else { $signature.SignerCertificate.Thumbprint }
    timestamp_subject = if ($null -eq $signature.TimeStamperCertificate) { $null } else { $signature.TimeStamperCertificate.Subject }
    timestamp_thumbprint = if ($null -eq $signature.TimeStamperCertificate) { $null } else { $signature.TimeStamperCertificate.Thumbprint }
  }
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  [Console]::Write(($value | ConvertTo-Json -Compress))
} catch {
  exit 7
}
"""
    completed = _run_native(
        [
            str(powershell_path),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            script,
        ],
        target=target,
        deadline=deadline,
    )
    if completed.returncode != 0:
        raise WindowsSignatureVerificationError("native_tool_failed")
    try:
        value = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise WindowsSignatureVerificationError("signer_metadata_invalid") from error
    if not isinstance(value, dict):
        raise WindowsSignatureVerificationError("signer_metadata_invalid")
    required_strings = (value.get("status"), value.get("signature_type"))
    optional_strings = (
        value.get("signer_subject"),
        value.get("signer_thumbprint"),
        value.get("timestamp_subject"),
        value.get("timestamp_thumbprint"),
    )
    if any(not isinstance(item, str) for item in required_strings) or any(
        item is not None and not isinstance(item, str) for item in optional_strings
    ):
        raise WindowsSignatureVerificationError("signer_metadata_invalid")
    return AuthenticodeMetadata(
        status=value["status"],
        signature_type=value["signature_type"],
        signer_subject=value.get("signer_subject"),
        signer_thumbprint=value.get("signer_thumbprint"),
        timestamp_subject=value.get("timestamp_subject"),
        timestamp_thumbprint=value.get("timestamp_thumbprint"),
    )


def parse_signtool_policy(output: bytes) -> tuple[str, str]:
    """Require one embedded SHA-256 signature with an RFC 3161 timestamp."""
    if len(output) > MAX_NATIVE_OUTPUT_BYTES:
        raise WindowsSignatureVerificationError("native_output_oversized")
    text = output.decode("utf-8", errors="replace")
    rows = list(_SIGNATURE_ROW.finditer(text))
    if len(rows) != 1 or rows[0].group("index") != "0":
        raise WindowsSignatureVerificationError("signature_policy_unproven")
    algorithm = rows[0].group("algorithm").casefold()
    timestamp = rows[0].group("timestamp").casefold()
    if algorithm != "sha256" or timestamp != "rfc3161":
        raise WindowsSignatureVerificationError("signature_policy_unproven")
    return algorithm, timestamp


def _read_timestamp_message_imprint(target: Path) -> TimestampMessageImprint:
    try:
        return read_timestamp_message_imprint(target)
    except TimestampPolicyError as error:
        raise WindowsSignatureVerificationError("timestamp_policy_unproven") from error


def _bounded_certificate_field(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    if (
        not value
        or len(value) > MAX_SIGNER_SUBJECT_CHARS
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        return None
    return value


def _verify_pe(
    target: Path,
    *,
    relative_path: str,
    sha256: str,
    expected_subject: str,
    expected_thumbprint: str,
    signtool_path: Path,
    powershell_path: Path,
    deadline: float,
) -> VerifiedPeSignature:
    signtool = _run_native(
        [
            str(signtool_path),
            "verify",
            "/pa",
            "/all",
            "/tw",
            "/sha1",
            expected_thumbprint,
            str(target),
        ],
        target=target,
        deadline=deadline,
    )
    metadata = _read_authenticode_metadata(
        target,
        powershell_path=powershell_path,
        deadline=deadline,
    )
    if metadata.status == "NotSigned":
        raise WindowsSignatureVerificationError("signature_missing", relative_path)
    if metadata.status != "Valid":
        raise WindowsSignatureVerificationError("signature_invalid", relative_path)
    if metadata.signature_type != "Authenticode":
        raise WindowsSignatureVerificationError("signature_type_invalid", relative_path)

    signer_subject = _bounded_certificate_field(metadata.signer_subject)
    timestamp_subject = _bounded_certificate_field(metadata.timestamp_subject)
    try:
        signer_thumbprint = _normalize_thumbprint(metadata.signer_thumbprint or "")
        timestamp_thumbprint = _normalize_thumbprint(
            metadata.timestamp_thumbprint or ""
        )
    except WindowsSignatureVerificationError as error:
        raise WindowsSignatureVerificationError(
            "signer_metadata_invalid", relative_path
        ) from error
    if signer_subject is None or timestamp_subject is None:
        if timestamp_subject is None:
            raise WindowsSignatureVerificationError("timestamp_missing", relative_path)
        raise WindowsSignatureVerificationError(
            "signer_metadata_invalid", relative_path
        )
    if signer_subject != expected_subject or signer_thumbprint != expected_thumbprint:
        raise WindowsSignatureVerificationError("signer_mismatch", relative_path)
    if signtool.returncode == 2:
        raise WindowsSignatureVerificationError("native_tool_warning", relative_path)
    if signtool.returncode != 0:
        raise WindowsSignatureVerificationError("signature_invalid", relative_path)
    parse_signtool_policy(signtool.stdout + b"\n" + signtool.stderr)
    try:
        timestamp_message_imprint = _read_timestamp_message_imprint(target)
    except WindowsSignatureVerificationError as error:
        raise WindowsSignatureVerificationError(error.code, relative_path) from error
    return VerifiedPeSignature(
        path=relative_path,
        sha256=sha256,
        signer_subject=signer_subject,
        signer_thumbprint=signer_thumbprint,
        timestamp_subject=timestamp_subject,
        timestamp_thumbprint=timestamp_thumbprint,
        timestamp_message_imprint_algorithm=timestamp_message_imprint.algorithm,
        timestamp_message_imprint=timestamp_message_imprint.digest,
    )


def verify_windows_signatures(
    root: Path,
    *,
    manifest_path: Path,
    surface: str,
    architecture: str,
    expected_signer_subject: str,
    expected_signer_thumbprint: str,
) -> WindowsSignatureReceipt:
    """Verify one stable post-signing Windows candidate and return its receipt."""
    if os.name != "nt":
        raise WindowsSignatureVerificationError("unsupported_platform")
    subject = _validate_subject(expected_signer_subject)
    thumbprint = _normalize_thumbprint(expected_signer_thumbprint)
    try:
        expected = load_inventory_manifest(manifest_path)
        before = inventory_native_code(
            root,
            platform="windows",
            surface=surface,
            architecture=architecture,
        )
    except NativeInventoryError as error:
        raise WindowsSignatureVerificationError("inventory_invalid") from error
    if expected != before.to_dict():
        raise WindowsSignatureVerificationError("inventory_mismatch")

    sign_tool = find_signtool()
    powershell = find_powershell()
    signtool_sha256 = _tool_sha256(sign_tool)
    powershell_sha256 = _tool_sha256(powershell)
    try:
        resolved_root = Path(root).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise WindowsSignatureVerificationError("inventory_invalid") from error
    for tool in (sign_tool, powershell):
        try:
            tool.relative_to(resolved_root)
        except ValueError:
            continue
        raise WindowsSignatureVerificationError("native_tool_failed")

    deadline = time.monotonic() + VERIFICATION_TIMEOUT_SECONDS
    verified: list[VerifiedPeSignature] = []
    for entry in before.native_code:
        target = resolved_root.joinpath(*entry.path.split("/"))
        try:
            verified.append(
                _verify_pe(
                    target,
                    relative_path=entry.path,
                    sha256=entry.sha256,
                    expected_subject=subject,
                    expected_thumbprint=thumbprint,
                    signtool_path=sign_tool,
                    powershell_path=powershell,
                    deadline=deadline,
                )
            )
        except WindowsSignatureVerificationError as error:
            if error.relative_path is None:
                raise WindowsSignatureVerificationError(
                    error.code, entry.path
                ) from error
            raise

    try:
        after = inventory_native_code(
            resolved_root,
            platform="windows",
            surface=surface,
            architecture=architecture,
        )
    except NativeInventoryError as error:
        raise WindowsSignatureVerificationError("candidate_changed") from error
    if expected != after.to_dict() or before.to_dict() != after.to_dict():
        raise WindowsSignatureVerificationError("candidate_changed")
    if signtool_sha256 != _tool_sha256(sign_tool) or powershell_sha256 != _tool_sha256(
        powershell
    ):
        raise WindowsSignatureVerificationError("native_tool_failed")

    signatures = tuple(verified)
    body = {
        "schema": SCHEMA,
        "surface": surface,
        "architecture": architecture,
        "candidate_sha256": after.candidate_sha256,
        "inventory_sha256": after.inventory_sha256,
        "signtool_sha256": signtool_sha256,
        "powershell_sha256": powershell_sha256,
        "expected_signer_subject": subject,
        "expected_signer_thumbprint": thumbprint,
        "native_code_count": len(signatures),
        "signatures": [item.to_dict() for item in signatures],
        "candidate_stable": True,
        "verified": True,
    }
    return WindowsSignatureReceipt(
        schema=SCHEMA,
        surface=surface,
        architecture=architecture,
        candidate_sha256=after.candidate_sha256,
        inventory_sha256=after.inventory_sha256,
        signtool_sha256=signtool_sha256,
        powershell_sha256=powershell_sha256,
        expected_signer_subject=subject,
        expected_signer_thumbprint=thumbprint,
        signatures=signatures,
        verification_sha256=canonical_sha256(body),
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify every PE in an exact post-signing Windows inventory.",
        epilog=(
            "Requires Windows, a registered Windows SDK SignTool, and system "
            "PowerShell. Receipt files must stay outside the candidate tree."
        ),
    )
    parser.add_argument(
        "--manifest",
        required=True,
        type=Path,
        help="Exact post-signing native inventory JSON to verify.",
    )
    parser.add_argument(
        "--surface",
        required=True,
        choices=("cli", "desktop"),
        help="Verify a cli or desktop candidate.",
    )
    parser.add_argument(
        "--architecture",
        required=True,
        choices=("x64", "arm64"),
        help="Verify an x64 or arm64 candidate.",
    )
    parser.add_argument(
        "--expected-signer-subject",
        required=True,
        help="Exact certificate subject required for every PE.",
    )
    parser.add_argument(
        "--expected-signer-thumbprint",
        required=True,
        help=(
            "Exact 40-hex certificate thumbprint used to select signer identity, "
            "not a content-digest policy."
        ),
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="Write canonical JSON to standard output for success or failure.",
    )
    output.add_argument(
        "--receipt",
        type=Path,
        metavar="PATH",
        help=(
            "Atomically write canonical JSON success or handled-failure evidence "
            "to PATH outside the candidate tree."
        ),
    )
    parser.add_argument(
        "root",
        type=Path,
        help="Candidate bundle root containing the inventoried PE files.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    receipt_path = None
    if args.receipt is not None:
        try:
            receipt_path = _validated_receipt_path(
                args.receipt,
                candidate_root=args.root,
                manifest_path=args.manifest,
            )
        except WindowsSignatureVerificationError as error:
            print(
                _canonical_json(
                    _failure_payload(
                        error,
                        surface=args.surface,
                        architecture=args.architecture,
                    )
                )
            )
            return 1
    try:
        receipt = verify_windows_signatures(
            args.root,
            manifest_path=args.manifest,
            surface=args.surface,
            architecture=args.architecture,
            expected_signer_subject=args.expected_signer_subject,
            expected_signer_thumbprint=args.expected_signer_thumbprint,
        )
    except WindowsSignatureVerificationError as error:
        if args.as_json or receipt_path is not None:
            _publish_json_payload(
                _failure_payload(
                    error,
                    surface=args.surface,
                    architecture=args.architecture,
                ),
                receipt_path=receipt_path,
                surface=args.surface,
                architecture=args.architecture,
            )
            return 1
        print(
            f"Windows signature verification failed [{error.code}]: {error}",
            file=sys.stderr,
        )
        return 1
    except (OSError, RuntimeError):
        if args.as_json or receipt_path is not None:
            _publish_json_payload(
                _failure_payload(
                    WindowsSignatureVerificationError("native_tool_failed"),
                    surface=args.surface,
                    architecture=args.architecture,
                ),
                receipt_path=receipt_path,
                surface=args.surface,
                architecture=args.architecture,
            )
            return 1
        print(
            "Windows signature verification failed [native_tool_failed]: "
            "verification could not complete",
            file=sys.stderr,
        )
        return 1
    if args.as_json or receipt_path is not None:
        published = _publish_json_payload(
            receipt.to_dict(),
            receipt_path=receipt_path,
            surface=args.surface,
            architecture=args.architecture,
        )
        return 0 if published else 1
    print(
        f"Windows signature policy verified {receipt.surface}/"
        f"{receipt.architecture}: {receipt.native_code_count} PE modules"
    )
    print(f"candidate sha256: {receipt.candidate_sha256}")
    print(f"inventory sha256: {receipt.inventory_sha256}")
    print(f"signtool sha256: {receipt.signtool_sha256}")
    print(f"powershell sha256: {receipt.powershell_sha256}")
    print(f"expected signer: {receipt.expected_signer_subject}")
    print(f"expected signer thumbprint: {receipt.expected_signer_thumbprint}")
    for signature in receipt.signatures:
        print(
            f"authenticode file-sha256={signature.sha256} "
            "timestamp-protocol=rfc3161 "
            "timestamp-message-imprint-sha256="
            f"{signature.timestamp_message_imprint} {signature.path}"
        )
    print(f"verification sha256: {receipt.verification_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
