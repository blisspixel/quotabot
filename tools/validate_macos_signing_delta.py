#!/usr/bin/env python3
"""Validate bounded file changes made by macOS signing or stapling."""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.create_macos_signing_plan import (  # noqa: E402
    MacOSSigningPlanError,
    canonical_macos_signing_plan_sha256,
    load_macos_signing_plan,
    signing_plan_from_inventory,
)
from tools.native_code_inventory import (  # noqa: E402
    MAX_CANDIDATE_BYTES,
    MAX_CANDIDATE_ENTRIES,
    MAX_CANDIDATE_FILES,
    MAX_NATIVE_CODE,
    MAX_RELATIVE_PATH_CHARS,
    NativeInventoryError,
    canonical_sha256,
    load_inventory_manifest,
)


SCHEMA = "quotabot.macos-signing-delta.v1"
ERROR_SCHEMA = "quotabot.macos-signing-delta-error.v1"
MAX_RECEIPT_BYTES = 128 * 1024
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_ARCHITECTURES = {"x86", "x64", "arm", "arm64"}
_OPERATIONS = {"signing", "stapling"}


class MacOSSigningDeltaError(ValueError):
    """A bounded macOS candidate-delta failure."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def _integer(value: object, *, minimum: int, maximum: int) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < minimum or value > maximum:
        return None
    return value


def _relative_path(value: object) -> str:
    if not isinstance(value, str):
        raise MacOSSigningDeltaError("inventory_invalid")
    parsed = PurePosixPath(value)
    if (
        not value
        or len(value) > MAX_RELATIVE_PATH_CHARS
        or value.startswith("/")
        or "\\" in value
        or parsed.is_absolute()
        or any(part in {"", ".", ".."} for part in parsed.parts)
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise MacOSSigningDeltaError("inventory_invalid")
    return value


def _link_target(value: object, *, relative: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > MAX_RELATIVE_PATH_CHARS
        or value.startswith("/")
        or "\\" in value
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise MacOSSigningDeltaError("inventory_invalid")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), value))
    if resolved in {"", ".", ".."} or resolved.startswith("../"):
        raise MacOSSigningDeltaError("inventory_invalid")
    return value


def validated_macos_inventory(value: dict[str, object]) -> dict[str, object]:
    if (
        value.get("schema") != "quotabot.signing-inventory.v1"
        or value.get("platform") != "macos"
        or value.get("surface") not in {"cli", "desktop"}
        or value.get("architecture") not in {"x64", "arm64"}
        or set(value)
        != {
            "schema",
            "platform",
            "surface",
            "architecture",
            "candidate_file_count",
            "candidate_bytes",
            "candidate_sha256",
            "candidate_entry_count",
            "candidate_entries",
            "native_code_count",
            "native_code",
            "inventory_sha256",
        }
    ):
        raise MacOSSigningDeltaError("inventory_invalid")

    entries = value.get("candidate_entries")
    native_code = value.get("native_code")
    if (
        not isinstance(entries, list)
        or not isinstance(native_code, list)
        or not entries
        or len(entries) > MAX_CANDIDATE_ENTRIES
        or len(native_code) == 0
        or len(native_code) > MAX_NATIVE_CODE
        or value.get("candidate_entry_count") != len(entries)
        or value.get("native_code_count") != len(native_code)
    ):
        raise MacOSSigningDeltaError("inventory_invalid")

    entry_paths: list[str] = []
    entry_by_path: dict[str, dict[str, object]] = {}
    file_count = 0
    candidate_bytes = 0
    for raw in entries:
        if not isinstance(raw, dict):
            raise MacOSSigningDeltaError("inventory_invalid")
        relative = _relative_path(raw.get("path"))
        kind = raw.get("kind")
        if kind == "file":
            if set(raw) != {"path", "kind", "bytes", "mode", "sha256"}:
                raise MacOSSigningDeltaError("inventory_invalid")
            size = _integer(raw.get("bytes"), minimum=0, maximum=MAX_CANDIDATE_BYTES)
            mode = _integer(raw.get("mode"), minimum=0, maximum=0o7777)
            digest = raw.get("sha256")
            if size is None or mode is None or not isinstance(digest, str):
                raise MacOSSigningDeltaError("inventory_invalid")
            if _SHA256.fullmatch(digest) is None:
                raise MacOSSigningDeltaError("inventory_invalid")
            file_count += 1
            candidate_bytes += size
        elif kind == "directory":
            if (
                set(raw) != {"path", "kind", "mode"}
                or _integer(raw.get("mode"), minimum=0, maximum=0o7777) is None
            ):
                raise MacOSSigningDeltaError("inventory_invalid")
        elif kind == "symlink":
            if set(raw) != {"path", "kind", "link_target"}:
                raise MacOSSigningDeltaError("inventory_invalid")
            _link_target(raw.get("link_target"), relative=relative)
        else:
            raise MacOSSigningDeltaError("inventory_invalid")
        entry_paths.append(relative)
        entry_by_path[relative] = raw

    if (
        entry_paths != sorted(entry_paths)
        or len(entry_by_path) != len(entry_paths)
        or len({path.casefold() for path in entry_paths}) != len(entry_paths)
        or file_count > MAX_CANDIDATE_FILES
        or candidate_bytes > MAX_CANDIDATE_BYTES
        or value.get("candidate_file_count") != file_count
        or value.get("candidate_bytes") != candidate_bytes
        or value.get("candidate_sha256") != canonical_sha256(entries)
    ):
        raise MacOSSigningDeltaError("inventory_invalid")

    native_paths: list[str] = []
    requested_architecture = str(value["architecture"])
    for raw in native_code:
        if not isinstance(raw, dict) or set(raw) != {
            "path",
            "kind",
            "architecture",
            "bytes",
            "sha256",
        }:
            raise MacOSSigningDeltaError("inventory_invalid")
        relative = _relative_path(raw.get("path"))
        architecture = raw.get("architecture")
        size = _integer(raw.get("bytes"), minimum=1, maximum=MAX_CANDIDATE_BYTES)
        digest = raw.get("sha256")
        architectures = architecture.split("+") if isinstance(architecture, str) else []
        file_entry = entry_by_path.get(relative)
        if (
            raw.get("kind") != "macho"
            or size is None
            or not isinstance(digest, str)
            or _SHA256.fullmatch(digest) is None
            or not architectures
            or len(set(architectures)) != len(architectures)
            or any(item not in _ARCHITECTURES for item in architectures)
            or requested_architecture not in architectures
            or file_entry is None
            or file_entry.get("kind") != "file"
            or file_entry.get("bytes") != size
            or file_entry.get("sha256") != digest
        ):
            raise MacOSSigningDeltaError("inventory_invalid")
        native_paths.append(relative)
    if native_paths != sorted(native_paths) or len(set(native_paths)) != len(
        native_paths
    ):
        raise MacOSSigningDeltaError("inventory_invalid")

    body = {key: item for key, item in value.items() if key != "inventory_sha256"}
    if (
        not isinstance(value.get("inventory_sha256"), str)
        or _SHA256.fullmatch(str(value["inventory_sha256"])) is None
        or value["inventory_sha256"] != canonical_sha256(body)
    ):
        raise MacOSSigningDeltaError("inventory_invalid")
    return value


def _load_inventory(path: Path) -> dict[str, object]:
    try:
        value = load_inventory_manifest(path)
    except NativeInventoryError as error:
        raise MacOSSigningDeltaError("inventory_invalid") from error
    return validated_macos_inventory(value)


def _load_plan(path: Path) -> dict[str, object]:
    try:
        return load_macos_signing_plan(path)
    except MacOSSigningPlanError as error:
        raise MacOSSigningDeltaError("plan_invalid") from error


def _targets(plan: dict[str, object], *, kind: str) -> set[str]:
    targets = plan.get("targets")
    if not isinstance(targets, list):
        raise MacOSSigningDeltaError("plan_invalid")
    result: set[str] = set()
    for target in targets:
        if not isinstance(target, dict):
            raise MacOSSigningDeltaError("plan_invalid")
        if target.get("kind") == kind:
            result.add(_relative_path(target.get("path")))
    return result


def _signature_metadata_path(relative: str, bundles: set[str]) -> bool:
    path_parts = PurePosixPath(relative).parts
    for bundle in bundles:
        bundle_parts = PurePosixPath(bundle).parts
        if path_parts[: len(bundle_parts)] != bundle_parts:
            continue
        remainder = path_parts[len(bundle_parts) :]
        if "_CodeSignature" in remainder:
            return True
    return False


def _entry_changes(
    before: dict[str, object],
    after: dict[str, object],
) -> bool:
    return before != after


def validate_macos_signing_delta(
    before_manifest: Path,
    after_manifest: Path,
    plan_path: Path,
    *,
    operation: str,
) -> dict[str, object]:
    """Validate one exact macOS signing or stapling inventory transition."""
    if operation not in _OPERATIONS:
        raise MacOSSigningDeltaError("operation_invalid")
    before = _load_inventory(before_manifest)
    after = _load_inventory(after_manifest)
    plan = _load_plan(plan_path)
    if (
        before["surface"] != after["surface"]
        or before["architecture"] != after["architecture"]
        or plan.get("surface") != before["surface"]
        or plan.get("architecture") != before["architecture"]
    ):
        raise MacOSSigningDeltaError("scope_mismatch")

    planned_native = _targets(plan, kind="macho")
    planned_bundles = _targets(plan, kind="bundle")
    before_native = {
        str(entry["path"]): entry
        for entry in before["native_code"]  # type: ignore[index]
    }
    after_native = {
        str(entry["path"]): entry
        for entry in after["native_code"]  # type: ignore[index]
    }
    if (
        not planned_native
        or set(before_native) != planned_native
        or set(after_native) != planned_native
    ):
        raise MacOSSigningDeltaError("native_set_changed")
    if operation == "signing":
        try:
            expected_plan = signing_plan_from_inventory(before)
        except MacOSSigningPlanError as error:
            raise MacOSSigningDeltaError("plan_invalid") from error
        if expected_plan != plan:
            raise MacOSSigningDeltaError("plan_mismatch")
    elif not planned_bundles:
        raise MacOSSigningDeltaError("stapling_requires_bundle")

    before_entries = {
        str(entry["path"]): entry
        for entry in before["candidate_entries"]  # type: ignore[index]
    }
    after_entries = {
        str(entry["path"]): entry
        for entry in after["candidate_entries"]  # type: ignore[index]
    }
    removed = set(before_entries) - set(after_entries)
    if removed:
        raise MacOSSigningDeltaError("path_removed")

    added_count = 0
    metadata_change_count = 0
    native_change_count = 0
    for relative, after_entry in after_entries.items():
        before_entry = before_entries.get(relative)
        metadata_path = _signature_metadata_path(relative, planned_bundles)
        if before_entry is None:
            if not metadata_path or after_entry.get("kind") not in {
                "file",
                "directory",
            }:
                raise MacOSSigningDeltaError("path_added_outside_signature_metadata")
            added_count += 1
            metadata_change_count += 1
            continue
        if not _entry_changes(before_entry, after_entry):
            continue
        if before_entry.get("kind") != after_entry.get("kind"):
            raise MacOSSigningDeltaError("kind_changed")
        if relative in planned_native:
            if operation != "signing":
                raise MacOSSigningDeltaError("native_changed_during_stapling")
            if before_entry.get("mode") != after_entry.get("mode"):
                raise MacOSSigningDeltaError("mode_changed")
            native_change_count += 1
            continue
        if not metadata_path:
            if before_entry.get("mode") != after_entry.get("mode"):
                raise MacOSSigningDeltaError("mode_changed")
            raise MacOSSigningDeltaError("content_changed_outside_plan")
        if before_entry.get("kind") == "symlink":
            raise MacOSSigningDeltaError("signature_metadata_link_changed")
        metadata_change_count += 1

    for relative in planned_native:
        before_entry = before_entries[relative]
        after_entry = after_entries[relative]
        changed = before_entry.get("bytes") != after_entry.get(
            "bytes"
        ) or before_entry.get("sha256") != after_entry.get("sha256")
        if operation == "signing" and not changed:
            raise MacOSSigningDeltaError("planned_native_unchanged")
        if operation == "stapling" and changed:
            raise MacOSSigningDeltaError("native_changed_during_stapling")
        before_native_entry = before_native[relative]
        after_native_entry = after_native[relative]
        if (
            before_native_entry.get("kind") != after_native_entry.get("kind")
            or before_native_entry.get("architecture")
            != after_native_entry.get("architecture")
            or before_native_entry.get("bytes") != before_entry.get("bytes")
            or before_native_entry.get("sha256") != before_entry.get("sha256")
            or after_native_entry.get("bytes") != after_entry.get("bytes")
            or after_native_entry.get("sha256") != after_entry.get("sha256")
        ):
            raise MacOSSigningDeltaError("native_metadata_invalid")

    if (
        operation == "signing"
        and before["candidate_sha256"] == after["candidate_sha256"]
    ):
        raise MacOSSigningDeltaError("candidate_unchanged")

    return {
        "schema": SCHEMA,
        "ok": True,
        "operation": operation,
        "surface": before["surface"],
        "architecture": before["architecture"],
        "before_candidate_sha256": before["candidate_sha256"],
        "after_candidate_sha256": after["candidate_sha256"],
        "before_inventory_sha256": before["inventory_sha256"],
        "after_inventory_sha256": after["inventory_sha256"],
        "plan_sha256": canonical_macos_signing_plan_sha256(plan),
        "planned_native_count": len(planned_native),
        "changed_native_count": native_change_count,
        "signature_metadata_change_count": metadata_change_count,
        "added_signature_metadata_count": added_count,
    }


def load_macos_signing_delta_receipt(
    path: Path,
    *,
    operation: str,
    surface: str,
) -> dict[str, object]:
    """Load one bounded, internally consistent successful delta receipt."""
    if operation not in _OPERATIONS or surface not in {"cli", "desktop"}:
        raise MacOSSigningDeltaError("receipt_scope_invalid")
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > MAX_RECEIPT_BYTES
        ):
            raise MacOSSigningDeltaError("receipt_invalid")
        value = json.loads(path.read_text(encoding="ascii"))
    except MacOSSigningDeltaError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MacOSSigningDeltaError("receipt_invalid") from error
    expected_keys = {
        "schema",
        "ok",
        "operation",
        "surface",
        "architecture",
        "before_candidate_sha256",
        "after_candidate_sha256",
        "before_inventory_sha256",
        "after_inventory_sha256",
        "plan_sha256",
        "planned_native_count",
        "changed_native_count",
        "signature_metadata_change_count",
        "added_signature_metadata_count",
    }
    digest_fields = (
        "before_candidate_sha256",
        "after_candidate_sha256",
        "before_inventory_sha256",
        "after_inventory_sha256",
        "plan_sha256",
    )
    if (
        not isinstance(value, dict)
        or set(value) != expected_keys
        or value.get("schema") != SCHEMA
        or value.get("ok") is not True
        or value.get("operation") != operation
        or value.get("surface") != surface
        or value.get("architecture") not in {"x64", "arm64"}
        or any(
            not isinstance(value.get(field), str)
            or _SHA256.fullmatch(str(value[field])) is None
            for field in digest_fields
        )
    ):
        raise MacOSSigningDeltaError("receipt_invalid")
    count_fields = (
        "planned_native_count",
        "changed_native_count",
        "signature_metadata_change_count",
        "added_signature_metadata_count",
    )
    if any(
        not isinstance(value.get(field), int)
        or isinstance(value.get(field), bool)
        or int(value[field]) < 0
        or int(value[field]) > MAX_CANDIDATE_ENTRIES
        for field in count_fields
    ):
        raise MacOSSigningDeltaError("receipt_invalid")
    if (
        int(value["planned_native_count"]) <= 0
        or int(value["changed_native_count"]) > int(value["planned_native_count"])
        or int(value["added_signature_metadata_count"])
        > int(value["signature_metadata_change_count"])
        or (operation == "stapling" and int(value["changed_native_count"]) != 0)
    ):
        raise MacOSSigningDeltaError("receipt_invalid")
    return value


def _publish_receipt(path: Path, receipt: dict[str, object]) -> None:
    payload = (
        json.dumps(receipt, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")
    if not payload or len(payload) > MAX_RECEIPT_BYTES:
        raise MacOSSigningDeltaError("receipt_too_large")
    descriptor = -1
    temporary: Path | None = None
    try:
        parent = path.parent.resolve(strict=True)
        if path.name in {"", ".", ".."} or path.is_symlink():
            raise MacOSSigningDeltaError("receipt_path_invalid")
        if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
            raise MacOSSigningDeltaError("receipt_path_invalid")
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
        saved = parent / path.name
        metadata = saved.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size != len(payload)
            or saved.read_bytes() != payload
        ):
            raise MacOSSigningDeltaError("receipt_write_failed")
    except MacOSSigningDeltaError:
        raise
    except OSError as error:
        raise MacOSSigningDeltaError("receipt_write_failed") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate an exact macOS signing or stapling inventory delta."
    )
    parser.add_argument(
        "--before", "--unsigned", dest="before", required=True, type=Path
    )
    parser.add_argument("--after", "--signed", dest="after", required=True, type=Path)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument(
        "--operation", required=True, choices=tuple(sorted(_OPERATIONS))
    )
    parser.add_argument("--receipt", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    try:
        receipt = validate_macos_signing_delta(
            args.before,
            args.after,
            args.plan,
            operation=args.operation,
        )
        _publish_receipt(args.receipt, receipt)
    except MacOSSigningDeltaError as error:
        failure = {"schema": ERROR_SCHEMA, "ok": False, "code": error.code}
        try:
            _publish_receipt(args.receipt, failure)
        except MacOSSigningDeltaError as receipt_error:
            failure["receipt_error_code"] = receipt_error.code
        print(json.dumps(failure, separators=(",", ":"), sort_keys=True))
        return 1
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "operation": receipt["operation"],
                "changed_native_count": receipt["changed_native_count"],
                "signature_metadata_change_count": receipt[
                    "signature_metadata_change_count"
                ],
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
