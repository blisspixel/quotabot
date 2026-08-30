#!/usr/bin/env python3
"""Apply and verify an exact macOS Developer ID signing plan."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.create_macos_signing_plan import (  # noqa: E402
    MacOSSigningPlanError,
    canonical_macos_signing_plan_sha256,
    load_macos_signing_plan,
    signing_plan_from_inventory,
)
from tools.macos_codesign_output import (  # noqa: E402
    MacOSCodeSignOutputError,
    code_directory_details,
    embedded_entitlements,
)
from tools.native_code_inventory import (  # noqa: E402
    NativeInventoryError,
    inventory_native_code,
    load_inventory_manifest,
)


SCHEMA = "quotabot.macos-signing.v1"
ERROR_SCHEMA = "quotabot.macos-signing-error.v1"
MAX_IDENTITY_CHARS = 256
MAX_TOOL_OUTPUT_CHARS = 256 * 1024
MAX_RECEIPT_BYTES = 128 * 1024
CLI_IDENTIFIER = "io.quotabot.cli"
_TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")
_CDHASH = re.compile(r"^[0-9a-f]{40}$")
_ARCH_NAMES = {"x64": "x86_64", "arm64": "arm64"}


class MacOSSigningError(RuntimeError):
    """A bounded signing failure that does not expose native diagnostics."""

    def __init__(self, code: str, *, target: str | None = None):
        self.code = code
        self.target = target
        super().__init__(code)


def _regular_file(path: Path, error_code: str) -> Path:
    try:
        if path.is_symlink():
            raise MacOSSigningError(error_code)
        resolved = path.resolve(strict=True)
        if not stat.S_ISREG(resolved.lstat().st_mode):
            raise MacOSSigningError(error_code)
        return resolved
    except MacOSSigningError:
        raise
    except (OSError, RuntimeError) as error:
        raise MacOSSigningError(error_code) from error


def _validate_identity(identity: str, team_id: str) -> None:
    if (
        not identity.startswith("Developer ID Application: ")
        or len(identity) > MAX_IDENTITY_CHARS
        or any(ord(character) < 32 or ord(character) == 127 for character in identity)
        or _TEAM_ID.fullmatch(team_id) is None
        or not identity.endswith(f" ({team_id})")
    ):
        raise MacOSSigningError("identity_invalid")


def _target_path(root: Path, relative: str) -> Path:
    try:
        requested = root.joinpath(*relative.split("/"))
        if requested.is_symlink():
            raise MacOSSigningError("target_invalid", target=relative)
        resolved = requested.resolve(strict=True)
        resolved.relative_to(root)
        return resolved
    except MacOSSigningError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise MacOSSigningError("target_invalid", target=relative) from error


def _run(
    command: list[str],
    *,
    code: str,
    target: str,
    runner: Callable[..., subprocess.CompletedProcess[str]],
) -> str:
    try:
        completed = runner(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=180,
            env=os.environ.copy(),
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise MacOSSigningError(code, target=target) from error
    output = f"{completed.stdout}\n{completed.stderr}"
    if completed.returncode != 0 or len(output) > MAX_TOOL_OUTPUT_CHARS:
        raise MacOSSigningError(code, target=target)
    return output


def _plist(path: Path) -> dict[str, object]:
    try:
        value = plistlib.loads(_regular_file(path, "entitlements_invalid").read_bytes())
    except MacOSSigningError:
        raise
    except (OSError, plistlib.InvalidFileException) as error:
        raise MacOSSigningError("entitlements_invalid") from error
    if not isinstance(value, dict):
        raise MacOSSigningError("entitlements_invalid")
    return value


def _embedded_entitlements(output: str, *, target: str) -> dict[str, object]:
    try:
        return embedded_entitlements(output)
    except MacOSCodeSignOutputError as error:
        raise MacOSSigningError(
            "entitlements_verification_failed", target=target
        ) from error


def _signature_details(
    output: str,
    *,
    identity: str,
    team_id: str,
    target: str,
) -> str:
    try:
        cdhash = code_directory_details(
            output,
            identity=identity,
            team_id=team_id,
        )
    except MacOSCodeSignOutputError as error:
        raise MacOSSigningError(
            "signature_verification_failed", target=target
        ) from error
    assert cdhash is not None
    return cdhash


def _canonical_sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
        ).encode("ascii")
    ).hexdigest()


def _publish_receipt(path: Path, receipt: dict[str, object]) -> None:
    payload = (
        json.dumps(receipt, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")
    if len(payload) > MAX_RECEIPT_BYTES:
        raise MacOSSigningError("receipt_too_large")
    descriptor = -1
    temporary: Path | None = None
    try:
        parent = path.parent.resolve(strict=True)
        if path.name in {"", ".", ".."} or path.is_symlink():
            raise MacOSSigningError("receipt_path_invalid")
        if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
            raise MacOSSigningError("receipt_path_invalid")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=parent
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, parent / path.name)
        temporary = None
    except MacOSSigningError:
        raise
    except OSError as error:
        raise MacOSSigningError("receipt_write_failed") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def load_macos_signing_receipt(path: Path, *, surface: str) -> dict[str, object]:
    try:
        metadata = path.lstat()
        if (
            path.is_symlink()
            or not stat.S_ISREG(metadata.st_mode)
            or not 0 < metadata.st_size <= MAX_RECEIPT_BYTES
        ):
            raise MacOSSigningError("signing_receipt_invalid")
        value = json.loads(path.read_text(encoding="ascii"))
    except MacOSSigningError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MacOSSigningError("signing_receipt_invalid") from error
    if not isinstance(value, dict):
        raise MacOSSigningError("signing_receipt_invalid")
    directories = value.get("code_directories")
    digest_fields = (
        "unsigned_inventory_sha256",
        "plan_sha256",
        "identity_sha256",
        "entitlements_sha256",
        "code_directories_sha256",
    )
    if (
        value.get("schema") != SCHEMA
        or value.get("ok") is not True
        or value.get("surface") != surface
        or value.get("architecture") not in {"x64", "arm64"}
        or not isinstance(directories, list)
        or not directories
        or len(directories) > 1024
        or value.get("code_directory_count") != len(directories)
        or any(
            not isinstance(value.get(field), str)
            or re.fullmatch(r"[0-9a-f]{64}", str(value[field])) is None
            for field in digest_fields
        )
    ):
        raise MacOSSigningError("signing_receipt_invalid")
    normalized: list[dict[str, str]] = []
    for item in directories:
        if not isinstance(item, dict):
            raise MacOSSigningError("signing_receipt_invalid")
        entry = {
            "path": str(item.get("path", "")),
            "architecture": str(item.get("architecture", "")),
            "cdhash": str(item.get("cdhash", "")),
        }
        if (
            not entry["path"]
            or entry["architecture"] not in {"x86_64", "arm64"}
            or _CDHASH.fullmatch(entry["cdhash"]) is None
        ):
            raise MacOSSigningError("signing_receipt_invalid")
        normalized.append(entry)
    if (
        normalized
        != sorted(normalized, key=lambda item: (item["path"], item["architecture"]))
        or len({(item["path"], item["architecture"]) for item in normalized})
        != len(normalized)
        or _canonical_sha256(normalized) != value["code_directories_sha256"]
    ):
        raise MacOSSigningError("signing_receipt_invalid")
    return value


def apply_macos_signing_plan(
    root: Path,
    *,
    manifest_path: Path,
    plan_path: Path,
    identity: str,
    team_id: str,
    keychain_path: Path,
    entitlements_path: Path | None,
    receipt_path: Path,
    codesign_path: Path = Path("/usr/bin/codesign"),
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, object]:
    """Validate, sign, verify, and receipt every exact target in order."""
    _validate_identity(identity, team_id)
    codesign = _regular_file(codesign_path, "codesign_unavailable")
    keychain = _regular_file(keychain_path, "keychain_invalid")
    expected_entitlements = (
        _plist(entitlements_path) if entitlements_path is not None else None
    )
    try:
        root_resolved = Path(root).resolve(strict=True)
        manifest = load_inventory_manifest(manifest_path)
        plan = load_macos_signing_plan(plan_path)
        current = inventory_native_code(
            root_resolved,
            platform="macos",
            surface=str(plan["surface"]),
            architecture=str(plan["architecture"]),
        ).to_dict()
    except (
        NativeInventoryError,
        MacOSSigningPlanError,
        OSError,
        RuntimeError,
    ) as error:
        raise MacOSSigningError("candidate_validation_failed") from error
    if manifest != current or signing_plan_from_inventory(manifest) != plan:
        raise MacOSSigningError("candidate_validation_failed")
    if plan["surface"] == "desktop" and expected_entitlements is None:
        raise MacOSSigningError("entitlements_required")
    if plan["surface"] == "cli" and expected_entitlements is not None:
        raise MacOSSigningError("entitlements_unexpected")

    targets = plan["targets"]
    assert isinstance(targets, list)
    for target in targets:
        assert isinstance(target, dict)
        relative = str(target["path"])
        target_path = _target_path(root_resolved, relative)
        command = [
            str(codesign),
            "--force",
            "--sign",
            identity,
            "--keychain",
            str(keychain),
            "--options",
            "runtime",
            "--timestamp",
        ]
        if plan["surface"] == "cli" and relative == "bin/quotabot":
            command.extend(("--identifier", CLI_IDENTIFIER))
        if target.get("entitlements") == "app_release":
            assert entitlements_path is not None
            command.extend(("--entitlements", str(entitlements_path.resolve())))
        command.append(str(target_path))
        _run(command, code="codesign_failed", target=relative, runner=runner)

    native_architectures = {
        str(entry["path"]): str(entry["architecture"]).split("+")
        for entry in manifest["native_code"]
        if isinstance(entry, dict)
    }
    code_directories: list[dict[str, str]] = []
    for target in targets:
        assert isinstance(target, dict)
        relative = str(target["path"])
        target_path = _target_path(root_resolved, relative)
        verify = [str(codesign), "--verify", "--strict", "--verbose=4"]
        if target.get("kind") == "bundle":
            verify.append("--deep")
        verify.append(str(target_path))
        _run(verify, code="codesign_verify_failed", target=relative, runner=runner)
        entitlement_output = _run(
            [str(codesign), "--display", "--entitlements", ":-", str(target_path)],
            code="entitlements_verification_failed",
            target=relative,
            runner=runner,
        )
        embedded = _embedded_entitlements(entitlement_output, target=relative)
        expected = (
            expected_entitlements if target.get("entitlements") == "app_release" else {}
        )
        if embedded != expected:
            raise MacOSSigningError("entitlements_verification_failed", target=relative)
        if target.get("kind") != "macho":
            continue
        for architecture in native_architectures.get(relative, []):
            native_arch = _ARCH_NAMES.get(architecture)
            if native_arch is None:
                raise MacOSSigningError(
                    "signature_verification_failed", target=relative
                )
            details = _run(
                [
                    str(codesign),
                    "--display",
                    "--verbose=4",
                    "--arch",
                    native_arch,
                    str(target_path),
                ],
                code="signature_verification_failed",
                target=relative,
                runner=runner,
            )
            cdhash = _signature_details(
                details, identity=identity, team_id=team_id, target=relative
            )
            code_directories.append(
                {"path": relative, "architecture": native_arch, "cdhash": cdhash}
            )
    code_directories.sort(key=lambda item: (item["path"], item["architecture"]))
    receipt = {
        "schema": SCHEMA,
        "ok": True,
        "surface": plan["surface"],
        "architecture": plan["architecture"],
        "team_id": team_id,
        "identity_sha256": hashlib.sha256(identity.encode("utf-8")).hexdigest(),
        "unsigned_inventory_sha256": manifest["inventory_sha256"],
        "plan_sha256": canonical_macos_signing_plan_sha256(plan),
        "entitlements_sha256": _canonical_sha256(expected_entitlements or {}),
        "target_count": len(targets),
        "code_directory_count": len(code_directories),
        "code_directories": code_directories,
        "code_directories_sha256": _canonical_sha256(code_directories),
    }
    _publish_receipt(receipt_path, receipt)
    return receipt


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Sign and verify one exact macOS candidate from its plan."
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--keychain", required=True, type=Path)
    parser.add_argument("--entitlements", type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("root", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    try:
        receipt = apply_macos_signing_plan(
            args.root,
            manifest_path=args.manifest,
            plan_path=args.plan,
            identity=args.identity,
            team_id=args.team_id,
            keychain_path=args.keychain,
            entitlements_path=args.entitlements,
            receipt_path=args.receipt,
        )
    except MacOSSigningError as error:
        payload: dict[str, object] = {
            "schema": ERROR_SCHEMA,
            "ok": False,
            "code": error.code,
        }
        if error.target is not None:
            payload["target"] = error.target
        print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
        return 1
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "target_count": receipt["target_count"],
                "code_directory_count": receipt["code_directory_count"],
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
