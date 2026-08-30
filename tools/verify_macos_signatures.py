#!/usr/bin/env python3
"""Verify exact macOS signatures, entitlements, Gatekeeper, and notarization."""

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
from tools.record_macos_notarization import (  # noqa: E402
    MacOSNotarizationError,
    load_notarization_receipt,
)
from tools.sign_macos_candidate import CLI_IDENTIFIER  # noqa: E402
from tools.validate_macos_signing_delta import (  # noqa: E402
    MacOSSigningDeltaError,
    load_macos_signing_delta_receipt,
)


SCHEMA = "quotabot.macos-signature-verification.v1"
ERROR_SCHEMA = "quotabot.macos-signature-verification-error.v1"
MAX_TOOL_OUTPUT_CHARS = 256 * 1024
MAX_RECEIPT_BYTES = 128 * 1024
_TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")
_ARCH_NAMES = {"x64": "x86_64", "arm64": "arm64"}


class MacOSSignatureVerificationError(RuntimeError):
    """A bounded native-verification failure."""

    def __init__(self, code: str, *, target: str | None = None):
        self.code = code
        self.target = target
        super().__init__(code)


def _regular_file(path: Path, code: str) -> Path:
    try:
        if path.is_symlink():
            raise MacOSSignatureVerificationError(code)
        resolved = path.resolve(strict=True)
        if not stat.S_ISREG(resolved.lstat().st_mode):
            raise MacOSSignatureVerificationError(code)
        return resolved
    except MacOSSignatureVerificationError:
        raise
    except (OSError, RuntimeError) as error:
        raise MacOSSignatureVerificationError(code) from error


def _target_path(root: Path, relative: str) -> Path:
    try:
        requested = root.joinpath(*relative.split("/"))
        if requested.is_symlink():
            raise MacOSSignatureVerificationError("target_invalid", target=relative)
        resolved = requested.resolve(strict=True)
        resolved.relative_to(root)
        return resolved
    except MacOSSignatureVerificationError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise MacOSSignatureVerificationError(
            "target_invalid", target=relative
        ) from error


def _run(
    command: list[str],
    *,
    code: str,
    target: str | None,
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
        raise MacOSSignatureVerificationError(code, target=target) from error
    output = f"{completed.stdout}\n{completed.stderr}"
    if completed.returncode != 0 or len(output) > MAX_TOOL_OUTPUT_CHARS:
        raise MacOSSignatureVerificationError(code, target=target)
    return output


def _canonical_sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
        ).encode("ascii")
    ).hexdigest()


def _load_entitlements(path: Path) -> dict[str, object]:
    try:
        value = plistlib.loads(_regular_file(path, "entitlements_invalid").read_bytes())
    except MacOSSignatureVerificationError:
        raise
    except (OSError, plistlib.InvalidFileException) as error:
        raise MacOSSignatureVerificationError("entitlements_invalid") from error
    if not isinstance(value, dict):
        raise MacOSSignatureVerificationError("entitlements_invalid")
    return value


def _embedded_entitlements(output: str, *, target: str) -> dict[str, object]:
    try:
        return embedded_entitlements(output)
    except MacOSCodeSignOutputError as error:
        raise MacOSSignatureVerificationError(
            "entitlements_verification_failed", target=target
        ) from error


def _validate_signature_details(
    output: str,
    *,
    identity: str,
    team_id: str,
    target: str,
    expected_identifier: str | None = None,
    require_cdhash: bool = False,
) -> str | None:
    try:
        return code_directory_details(
            output,
            identity=identity,
            team_id=team_id,
            expected_identifier=expected_identifier,
            require_cdhash=require_cdhash,
        )
    except MacOSCodeSignOutputError as error:
        raise MacOSSignatureVerificationError(
            "signature_policy_failed", target=target
        ) from error


def _publish_receipt(path: Path, receipt: dict[str, object]) -> None:
    payload = (
        json.dumps(receipt, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")
    if len(payload) > MAX_RECEIPT_BYTES:
        raise MacOSSignatureVerificationError("receipt_too_large")
    descriptor = -1
    temporary: Path | None = None
    try:
        parent = path.parent.resolve(strict=True)
        if path.name in {"", ".", ".."} or path.is_symlink():
            raise MacOSSignatureVerificationError("receipt_path_invalid")
        if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
            raise MacOSSignatureVerificationError("receipt_path_invalid")
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
    except MacOSSignatureVerificationError:
        raise
    except OSError as error:
        raise MacOSSignatureVerificationError("receipt_write_failed") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def verify_macos_signatures(
    root: Path,
    *,
    manifest_path: Path,
    signing_plan_path: Path,
    notarization_receipt_path: Path,
    stapling_delta_receipt_path: Path | None,
    surface: str,
    architecture: str,
    expected_identity: str,
    expected_team_id: str,
    expected_entitlements_path: Path | None,
    receipt_path: Path,
    codesign_path: Path = Path("/usr/bin/codesign"),
    spctl_path: Path = Path("/usr/sbin/spctl"),
    xcrun_path: Path = Path("/usr/bin/xcrun"),
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, object]:
    """Verify one exact signed candidate and its bound notarization evidence."""
    if (
        surface not in {"cli", "desktop"}
        or architecture not in {"x64", "arm64"}
        or _TEAM_ID.fullmatch(expected_team_id) is None
        or not expected_identity.startswith("Developer ID Application: ")
        or not expected_identity.endswith(f" ({expected_team_id})")
        or len(expected_identity) > 256
        or any(
            ord(character) < 32 or ord(character) == 127
            for character in expected_identity
        )
    ):
        raise MacOSSignatureVerificationError("policy_input_invalid")
    if surface == "desktop" and expected_entitlements_path is None:
        raise MacOSSignatureVerificationError("entitlements_required")
    if surface == "cli" and expected_entitlements_path is not None:
        raise MacOSSignatureVerificationError("entitlements_unexpected")
    if surface == "desktop" and stapling_delta_receipt_path is None:
        raise MacOSSignatureVerificationError("stapling_delta_required")
    if surface == "cli" and stapling_delta_receipt_path is not None:
        raise MacOSSignatureVerificationError("stapling_delta_unexpected")
    expected_entitlements = (
        _load_entitlements(expected_entitlements_path)
        if expected_entitlements_path is not None
        else {}
    )
    codesign = _regular_file(codesign_path, "codesign_unavailable")
    spctl = _regular_file(spctl_path, "spctl_unavailable")
    xcrun = _regular_file(xcrun_path, "xcrun_unavailable")
    try:
        root_resolved = Path(root).resolve(strict=True)
        expected_inventory = load_inventory_manifest(manifest_path)
        current_inventory = inventory_native_code(
            root_resolved,
            platform="macos",
            surface=surface,
            architecture=architecture,
        ).to_dict()
        notarization = load_notarization_receipt(
            notarization_receipt_path,
            surface=surface,
        )
        plan = load_macos_signing_plan(signing_plan_path)
        current_plan = signing_plan_from_inventory(current_inventory)
        stapling_delta = (
            load_macos_signing_delta_receipt(
                stapling_delta_receipt_path,
                operation="stapling",
                surface="desktop",
            )
            if stapling_delta_receipt_path is not None
            else None
        )
    except (
        NativeInventoryError,
        MacOSSigningPlanError,
        MacOSNotarizationError,
        MacOSSigningDeltaError,
        OSError,
        RuntimeError,
    ) as error:
        raise MacOSSignatureVerificationError("candidate_validation_failed") from error
    plan_sha256 = canonical_macos_signing_plan_sha256(plan)
    if (
        expected_inventory != current_inventory
        or notarization["architecture"] != architecture
        or plan.get("surface") != surface
        or plan.get("architecture") != architecture
        or plan.get("targets") != current_plan.get("targets")
        or plan.get("target_count") != current_plan.get("target_count")
        or notarization.get("signing_plan_sha256") != plan_sha256
        or notarization.get("entitlements_sha256")
        != _canonical_sha256(expected_entitlements)
    ):
        raise MacOSSignatureVerificationError("candidate_validation_failed")
    if surface == "cli":
        if notarization.get("submitted_candidate_sha256") != current_inventory.get(
            "candidate_sha256"
        ) or notarization.get("submitted_inventory_sha256") != current_inventory.get(
            "inventory_sha256"
        ):
            raise MacOSSignatureVerificationError("notarization_binding_failed")
    else:
        assert stapling_delta is not None
        if (
            stapling_delta.get("architecture") != architecture
            or stapling_delta.get("plan_sha256") != plan_sha256
            or stapling_delta.get("before_candidate_sha256")
            != notarization.get("submitted_candidate_sha256")
            or stapling_delta.get("before_inventory_sha256")
            != notarization.get("submitted_inventory_sha256")
            or stapling_delta.get("after_candidate_sha256")
            != current_inventory.get("candidate_sha256")
            or stapling_delta.get("after_inventory_sha256")
            != current_inventory.get("inventory_sha256")
        ):
            raise MacOSSignatureVerificationError("notarization_binding_failed")

    targets = plan["targets"]
    assert isinstance(targets, list)
    native_architectures = {
        str(entry["path"]): str(entry["architecture"]).split("+")
        for entry in current_inventory["native_code"]
        if isinstance(entry, dict)
    }
    verified_paths: list[str] = []
    current_code_directories: list[dict[str, str]] = []
    for target in targets:
        assert isinstance(target, dict)
        relative = str(target["path"])
        path = _target_path(root_resolved, relative)
        verify_command = [str(codesign), "--verify", "--strict", "--verbose=4"]
        if target.get("kind") == "bundle":
            verify_command.append("--deep")
        verify_command.append(str(path))
        _run(
            verify_command,
            code="codesign_verify_failed",
            target=relative,
            runner=runner,
        )
        details = _run(
            [str(codesign), "--display", "--verbose=4", str(path)],
            code="codesign_details_failed",
            target=relative,
            runner=runner,
        )
        _validate_signature_details(
            details,
            identity=expected_identity,
            team_id=expected_team_id,
            target=relative,
            expected_identifier=(
                CLI_IDENTIFIER
                if surface == "cli" and relative == "bin/quotabot"
                else None
            ),
        )
        entitlement_output = _run(
            [str(codesign), "--display", "--entitlements", ":-", str(path)],
            code="entitlements_verification_failed",
            target=relative,
            runner=runner,
        )
        embedded = _embedded_entitlements(entitlement_output, target=relative)
        expected = (
            expected_entitlements if target.get("entitlements") == "app_release" else {}
        )
        if embedded != expected:
            raise MacOSSignatureVerificationError(
                "entitlements_verification_failed", target=relative
            )
        if target.get("kind") == "macho":
            for item_architecture in native_architectures.get(relative, []):
                native_arch = _ARCH_NAMES.get(item_architecture)
                if native_arch is None:
                    raise MacOSSignatureVerificationError(
                        "signature_policy_failed", target=relative
                    )
                arch_details = _run(
                    [
                        str(codesign),
                        "--display",
                        "--verbose=4",
                        "--arch",
                        native_arch,
                        str(path),
                    ],
                    code="codesign_details_failed",
                    target=relative,
                    runner=runner,
                )
                cdhash = _validate_signature_details(
                    arch_details,
                    identity=expected_identity,
                    team_id=expected_team_id,
                    target=relative,
                    expected_identifier=(
                        CLI_IDENTIFIER
                        if surface == "cli" and relative == "bin/quotabot"
                        else None
                    ),
                    require_cdhash=True,
                )
                assert cdhash is not None
                current_code_directories.append(
                    {"path": relative, "architecture": native_arch, "cdhash": cdhash}
                )
        verified_paths.append(relative)
    current_code_directories.sort(key=lambda item: (item["path"], item["architecture"]))
    if current_code_directories != notarization["submitted_code_directories"]:
        raise MacOSSignatureVerificationError("notarization_binding_failed")

    primary_relative = "bin/quotabot" if surface == "cli" else "quotabot.app"
    primary = _target_path(root_resolved, primary_relative)
    gatekeeper_output = _run(
        [str(spctl), "--assess", "--type", "execute", "--verbose=4", str(primary)],
        code="gatekeeper_assessment_failed",
        target=primary_relative,
        runner=runner,
    )
    gatekeeper_lines = {
        line.strip() for line in gatekeeper_output.splitlines() if line.strip()
    }
    if "source=Notarized Developer ID" not in gatekeeper_lines:
        raise MacOSSignatureVerificationError(
            "gatekeeper_notarization_failed", target=primary_relative
        )
    staple_valid = False
    if surface == "desktop":
        _run(
            [str(xcrun), "stapler", "validate", str(primary)],
            code="staple_validation_failed",
            target=primary_relative,
            runner=runner,
        )
        staple_valid = True

    receipt = {
        "schema": SCHEMA,
        "ok": True,
        "surface": surface,
        "architecture": architecture,
        "team_id": expected_team_id,
        "identity_sha256": hashlib.sha256(
            expected_identity.encode("utf-8")
        ).hexdigest(),
        "inventory_sha256": current_inventory["inventory_sha256"],
        "plan_sha256": plan_sha256,
        "entitlements_sha256": _canonical_sha256(expected_entitlements),
        "code_directories_sha256": _canonical_sha256(current_code_directories),
        "notarized_candidate_sha256": notarization["submitted_candidate_sha256"],
        "notarized_inventory_sha256": notarization["submitted_inventory_sha256"],
        "verified_target_count": len(verified_paths),
        "notarization_submission_id": notarization["submission_id"],
        "gatekeeper_assessed": True,
        "gatekeeper_source": "Notarized Developer ID",
        "staple_valid": staple_valid,
        "stapling_delta_bound": stapling_delta is not None,
    }
    _publish_receipt(receipt_path, receipt)
    return receipt


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify exact Developer ID signatures and notarization evidence."
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--signing-plan", required=True, type=Path)
    parser.add_argument("--notarization-receipt", required=True, type=Path)
    parser.add_argument("--stapling-delta-receipt", type=Path)
    parser.add_argument("--surface", required=True, choices=("cli", "desktop"))
    parser.add_argument("--architecture", required=True, choices=("x64", "arm64"))
    parser.add_argument("--expected-identity", required=True)
    parser.add_argument("--expected-team-id", required=True)
    parser.add_argument("--expected-entitlements", type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("root", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    try:
        receipt = verify_macos_signatures(
            args.root,
            manifest_path=args.manifest,
            signing_plan_path=args.signing_plan,
            notarization_receipt_path=args.notarization_receipt,
            stapling_delta_receipt_path=args.stapling_delta_receipt,
            surface=args.surface,
            architecture=args.architecture,
            expected_identity=args.expected_identity,
            expected_team_id=args.expected_team_id,
            expected_entitlements_path=args.expected_entitlements,
            receipt_path=args.receipt,
        )
    except MacOSSignatureVerificationError as error:
        failure: dict[str, object] = {
            "schema": ERROR_SCHEMA,
            "ok": False,
            "code": error.code,
        }
        if error.target is not None:
            failure["target"] = error.target
        try:
            _publish_receipt(args.receipt, failure)
        except MacOSSignatureVerificationError as receipt_error:
            failure["receipt_error_code"] = receipt_error.code
        print(json.dumps(failure, separators=(",", ":"), sort_keys=True))
        return 1
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "surface": receipt["surface"],
                "verified_target_count": receipt["verified_target_count"],
                "gatekeeper_source": receipt["gatekeeper_source"],
                "staple_valid": receipt["staple_valid"],
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
