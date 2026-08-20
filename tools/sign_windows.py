#!/usr/bin/env python3
"""Sign every PE in an exact Windows inventory with Authenticode and RFC 3161."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.native_code_inventory import (  # noqa: E402
    NativeInventoryError,
    load_inventory_manifest,
)
from tools.verify_windows_signatures import (  # noqa: E402
    MAX_NATIVE_OUTPUT_BYTES,
    NATIVE_COMMAND_TIMEOUT_SECONDS,
    WindowsSignatureVerificationError,
    find_signtool,
)


SCHEMA = "quotabot.windows-sign.v1"
ERROR_SCHEMA = "quotabot.windows-sign-error.v1"
MAX_PFX_BYTES = 1024 * 1024
MAX_PASSWORD_CHARS = 256
MAX_TIMESTAMP_URL_CHARS = 256
SIGN_TIMEOUT_SECONDS = 300.0
NATIVE_CODE_LIMIT = 512

_ERROR_MESSAGES = {
    "unsupported_platform": "Windows Authenticode signing requires Windows",
    "missing_signing_secret": "a required Windows signing secret or timestamp URL is missing",
    "invalid_timestamp_url": "Windows timestamp URL is missing or invalid",
    "invalid_pfx": "Windows signing certificate cannot be decoded",
    "inventory_invalid": "unsigned inventory cannot be used for signing",
    "native_code_empty": "unsigned inventory contains no PE files to sign",
    "path_outside_candidate": "inventory path is outside the candidate tree",
    "signtool_unavailable": "SignTool is unavailable or untrusted",
    "sign_timeout": "Authenticode signing timed out",
    "sign_failed": "Authenticode signing failed",
}


class WindowsSignError(ValueError):
    """A bounded, secret-safe signing failure."""

    def __init__(self, code: str, relative_path: str | None = None):
        if code not in _ERROR_MESSAGES:
            raise ValueError(f"unknown signing error code: {code}")
        self.code = code
        self.relative_path = relative_path
        super().__init__(code)

    def __str__(self) -> str:
        message = _ERROR_MESSAGES[self.code]
        if self.relative_path is not None:
            return f"{message}: {self.relative_path}"
        return message


def _required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not isinstance(value, str) or not value.strip():
        raise WindowsSignError("missing_signing_secret")
    return value


def validate_timestamp_url(value: str) -> str:
    url = value.strip()
    if not url or len(url) > MAX_TIMESTAMP_URL_CHARS:
        raise WindowsSignError("invalid_timestamp_url")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise WindowsSignError("invalid_timestamp_url")
    if parsed.username is not None or parsed.password is not None:
        raise WindowsSignError("invalid_timestamp_url")
    host = parsed.hostname
    if not host or host in {"localhost", "127.0.0.1", "::1"}:
        raise WindowsSignError("invalid_timestamp_url")
    if parsed.query or parsed.fragment:
        raise WindowsSignError("invalid_timestamp_url")
    return url


def _decode_pfx(raw: str) -> bytes:
    compact = "".join(raw.split())
    try:
        decoded = base64.b64decode(compact, validate=True)
    except (binascii.Error, ValueError) as error:
        raise WindowsSignError("invalid_pfx") from error
    if not decoded or len(decoded) > MAX_PFX_BYTES:
        raise WindowsSignError("invalid_pfx")
    return decoded


def _validate_password(password: str) -> str:
    if len(password) > MAX_PASSWORD_CHARS:
        raise WindowsSignError("missing_signing_secret")
    if any(ord(character) < 32 or ord(character) == 127 for character in password):
        raise WindowsSignError("missing_signing_secret")
    return password


def redact_secret(text: str, secret: str) -> str:
    if not secret:
        return text
    return text.replace(secret, "[redacted]")


def sign_command(
    signtool: Path,
    pfx: Path,
    password: str,
    timestamp_url: str,
    target: Path,
) -> list[str]:
    return [
        str(signtool),
        "sign",
        "/fd",
        "SHA256",
        "/td",
        "SHA256",
        "/tr",
        timestamp_url,
        "/f",
        str(pfx),
        "/p",
        password,
        str(target),
    ]


def _inventory_targets(
    manifest: Path,
    candidate: Path,
    *,
    surface: str,
    architecture: str,
) -> list[tuple[str, Path]]:
    try:
        payload = load_inventory_manifest(manifest)
    except NativeInventoryError as error:
        raise WindowsSignError("inventory_invalid") from error
    if payload.get("platform") != "windows":
        raise WindowsSignError("inventory_invalid")
    if payload.get("surface") != surface or payload.get("architecture") != architecture:
        raise WindowsSignError("inventory_invalid")
    native_code = payload.get("native_code")
    if not isinstance(native_code, list):
        raise WindowsSignError("inventory_invalid")
    if not native_code:
        raise WindowsSignError("native_code_empty")
    if len(native_code) > NATIVE_CODE_LIMIT:
        raise WindowsSignError("inventory_invalid")
    try:
        root = candidate.resolve()
    except OSError as error:
        raise WindowsSignError("path_outside_candidate") from error
    targets: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for entry in native_code:
        if not isinstance(entry, dict):
            raise WindowsSignError("inventory_invalid")
        relative = entry.get("path")
        if not isinstance(relative, str) or not relative or relative in seen:
            raise WindowsSignError("inventory_invalid")
        seen.add(relative)
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise WindowsSignError("path_outside_candidate", relative)
        try:
            target = (root / relative).resolve()
        except OSError as error:
            raise WindowsSignError("path_outside_candidate", relative) from error
        if not target.is_relative_to(root):
            raise WindowsSignError("path_outside_candidate", relative)
        if not target.is_file():
            raise WindowsSignError("path_outside_candidate", relative)
        targets.append((relative, target))
    return targets


def _run_signtool(command: list[str], password: str, pfx_b64: str) -> None:
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        completed = subprocess.run(
            command,
            cwd=Path(command[0]).parent,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=NATIVE_COMMAND_TIMEOUT_SECONDS,
            creationflags=creation_flags,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise WindowsSignError("sign_timeout") from error
    except OSError as error:
        raise WindowsSignError("sign_failed") from error
    output = completed.stdout[:MAX_NATIVE_OUTPUT_BYTES].decode("utf-8", "replace")
    output = redact_secret(redact_secret(output, password), pfx_b64)
    if completed.returncode != 0:
        raise WindowsSignError("sign_failed")
    if "failed" in output.casefold() and "successfully signed" not in output.casefold():
        raise WindowsSignError("sign_failed")


def sign_windows_candidate(
    candidate: Path,
    manifest: Path,
    *,
    surface: str,
    architecture: str,
) -> None:
    if os.name != "nt":
        raise WindowsSignError("unsupported_platform")
    pfx_b64 = _required_env("QUOTABOT_WINDOWS_PFX_BASE64")
    password = _validate_password(_required_env("QUOTABOT_WINDOWS_PFX_PASSWORD"))
    timestamp_url = validate_timestamp_url(
        _required_env("QUOTABOT_WINDOWS_TIMESTAMP_URL")
    )
    pfx_bytes = _decode_pfx(pfx_b64)
    try:
        signtool = find_signtool()
    except WindowsSignatureVerificationError as error:
        raise WindowsSignError("signtool_unavailable") from error
    targets = _inventory_targets(
        manifest,
        candidate,
        surface=surface,
        architecture=architecture,
    )
    handle, pfx_name = tempfile.mkstemp(prefix="quotabot-sign-", suffix=".pfx")
    pfx_path = Path(pfx_name)
    deadline = time.monotonic() + SIGN_TIMEOUT_SECONDS
    try:
        with os.fdopen(handle, "wb") as handle_file:
            handle_file.write(pfx_bytes)
        for relative, target in targets:
            if time.monotonic() > deadline:
                raise WindowsSignError("sign_timeout", relative)
            _run_signtool(
                sign_command(signtool, pfx_path, password, timestamp_url, target),
                password,
                pfx_b64,
            )
    finally:
        try:
            pfx_path.write_bytes(b"\x00" * min(pfx_path.stat().st_size, MAX_PFX_BYTES))
        except OSError:
            # Best-effort wipe of the temp PFX. Deletion still runs next.
            pass
        try:
            pfx_path.unlink()
        except OSError:
            # Temp-file cleanup must not mask a signing success or failure.
            pass


def _failure_payload(error: WindowsSignError) -> dict[str, object]:
    payload: dict[str, object] = {
        "schema": ERROR_SCHEMA,
        "ok": False,
        "code": error.code,
        "error": str(error),
    }
    if error.relative_path is not None:
        payload["path"] = error.relative_path
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Authenticode-sign every PE in an unsigned Windows inventory using "
            "SHA-256 file digests and an RFC 3161 SHA-256 timestamp."
        )
    )
    parser.add_argument(
        "--manifest",
        required=True,
        type=Path,
        help="Exact unsigned native inventory JSON listing PE files to sign.",
    )
    parser.add_argument(
        "--surface",
        required=True,
        choices=("cli", "desktop"),
        help="Sign a cli or desktop candidate.",
    )
    parser.add_argument(
        "--architecture",
        required=True,
        choices=("x64", "arm64"),
        help="Sign an x64 or arm64 candidate.",
    )
    parser.add_argument(
        "root",
        type=Path,
        help="Candidate bundle root containing the inventoried PE files.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.surface not in {"cli", "desktop"}:
            raise WindowsSignError("inventory_invalid")
        sign_windows_candidate(
            args.root,
            args.manifest,
            surface=args.surface,
            architecture=args.architecture,
        )
    except WindowsSignError as error:
        print(
            json.dumps(_failure_payload(error), separators=(",", ":"), sort_keys=True)
        )
        return 1
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "surface": args.surface,
                "architecture": args.architecture,
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
