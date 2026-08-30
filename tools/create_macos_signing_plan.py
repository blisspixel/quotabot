#!/usr/bin/env python3
"""Create an exact inside-out macOS signing plan from a trusted inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.native_code_inventory import (  # noqa: E402
    MAX_NATIVE_CODE,
    NativeInventoryError,
    inventory_native_code,
    load_inventory_manifest,
)


SCHEMA = "quotabot.macos-signing-plan.v1"
ERROR_SCHEMA = "quotabot.macos-signing-plan-error.v1"
MAX_PLAN_BYTES = 1024 * 1024
MAX_SIGNING_TARGETS = MAX_NATIVE_CODE * 2
_BUNDLE_SUFFIXES = (".appex", ".app", ".bundle", ".framework", ".plugin", ".xpc")


class MacOSSigningPlanError(ValueError):
    """A bounded, path-private signing-plan failure."""


def _validated_relative_path(value: object) -> str:
    if not isinstance(value, str):
        raise MacOSSigningPlanError("inventory contains an invalid native path")
    parsed = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or parsed.is_absolute()
        or any(part in {"", ".", ".."} for part in parsed.parts)
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise MacOSSigningPlanError("inventory contains an invalid native path")
    return value


def _bundle_ancestors(relative: str) -> tuple[str, ...]:
    parts = PurePosixPath(relative).parts[:-1]
    bundles: list[str] = []
    for index, part in enumerate(parts):
        if part.casefold().endswith(_BUNDLE_SUFFIXES):
            bundles.append(PurePosixPath(*parts[: index + 1]).as_posix())
    return tuple(bundles)


def signing_plan_from_inventory(inventory: dict[str, object]) -> dict[str, object]:
    if (
        inventory.get("schema") != "quotabot.signing-inventory.v1"
        or inventory.get("platform") != "macos"
        or inventory.get("surface") not in {"cli", "desktop"}
        or inventory.get("architecture") not in {"x64", "arm64"}
        or not isinstance(inventory.get("candidate_sha256"), str)
        or not isinstance(inventory.get("inventory_sha256"), str)
    ):
        raise MacOSSigningPlanError("macOS inventory is invalid")
    entries = inventory.get("native_code")
    if (
        not isinstance(entries, list)
        or not entries
        or len(entries) > MAX_NATIVE_CODE
        or inventory.get("native_code_count") != len(entries)
    ):
        raise MacOSSigningPlanError("macOS inventory is invalid")

    native_paths: list[str] = []
    bundle_paths: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("kind") != "macho":
            raise MacOSSigningPlanError("macOS inventory is invalid")
        relative = _validated_relative_path(entry.get("path"))
        native_paths.append(relative)
        bundle_paths.update(_bundle_ancestors(relative))
    if native_paths != sorted(native_paths) or len(native_paths) != len(
        set(native_paths)
    ):
        raise MacOSSigningPlanError("macOS inventory is invalid")

    surface = str(inventory["surface"])
    if surface == "desktop":
        if "quotabot.app" not in bundle_paths:
            raise MacOSSigningPlanError("desktop signing plan has no outer app")
    elif bundle_paths:
        raise MacOSSigningPlanError("CLI signing plan contains an unexpected bundle")

    native_targets = sorted(
        native_paths,
        key=lambda value: (-len(PurePosixPath(value).parts), value),
    )
    bundle_targets = sorted(
        bundle_paths,
        key=lambda value: (-len(PurePosixPath(value).parts), value),
    )
    targets: list[dict[str, object]] = [
        {"path": path, "kind": "macho", "entitlements": None} for path in native_targets
    ]
    targets.extend(
        {
            "path": path,
            "kind": "bundle",
            "entitlements": "app_release" if path == "quotabot.app" else None,
        }
        for path in bundle_targets
    )
    if not targets or len(targets) > MAX_SIGNING_TARGETS:
        raise MacOSSigningPlanError("macOS signing target count is invalid")
    return {
        "schema": SCHEMA,
        "platform": "macos",
        "surface": surface,
        "architecture": inventory["architecture"],
        "candidate_sha256": inventory["candidate_sha256"],
        "inventory_sha256": inventory["inventory_sha256"],
        "target_count": len(targets),
        "targets": targets,
    }


def _validated_output_path(output: Path, *, candidate_root: Path) -> Path:
    try:
        resolved_root = candidate_root.resolve(strict=True)
        requested = Path(output)
        parent = requested.parent.resolve(strict=True)
        if parent != resolved_root.parent or requested.name in {"", ".", ".."}:
            raise MacOSSigningPlanError("signing plan output path is invalid")
        if any(
            ord(character) < 32 or ord(character) == 127 for character in requested.name
        ):
            raise MacOSSigningPlanError("signing plan output path is invalid")
        if requested.exists() or requested.is_symlink():
            metadata = requested.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise MacOSSigningPlanError("signing plan output path is invalid")
        return parent / requested.name
    except MacOSSigningPlanError:
        raise
    except (OSError, RuntimeError) as error:
        raise MacOSSigningPlanError("signing plan output path is invalid") from error


def _publish_plan(path: Path, payload: bytes) -> None:
    if not payload or len(payload) > MAX_PLAN_BYTES:
        raise MacOSSigningPlanError("signing plan could not be published safely")
    descriptor = -1
    temporary: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != len(payload):
            raise MacOSSigningPlanError("signing plan could not be published safely")
        if path.read_bytes() != payload:
            raise MacOSSigningPlanError("signing plan could not be published safely")
    except MacOSSigningPlanError:
        raise
    except OSError as error:
        raise MacOSSigningPlanError(
            "signing plan could not be published safely"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def create_macos_signing_plan(
    root: Path,
    *,
    manifest_path: Path,
    output_path: Path,
    surface: str,
    architecture: str,
) -> dict[str, object]:
    """Validate a candidate and publish its exact inside-out signing plan."""
    try:
        expected = load_inventory_manifest(manifest_path)
        current = inventory_native_code(
            root,
            platform="macos",
            surface=surface,
            architecture=architecture,
        ).to_dict()
    except NativeInventoryError as error:
        raise MacOSSigningPlanError("macOS inventory cannot be validated") from error
    if expected != current:
        raise MacOSSigningPlanError("candidate does not match the complete inventory")
    plan = signing_plan_from_inventory(expected)
    output = _validated_output_path(output_path, candidate_root=Path(root))
    payload = (
        json.dumps(plan, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")
    _publish_plan(output, payload)
    return plan


def canonical_macos_signing_plan_sha256(plan: dict[str, object]) -> str:
    """Hash the canonical plan object independently of file serialization."""
    payload = json.dumps(
        plan, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("ascii")
    return hashlib.sha256(payload).hexdigest()


def load_macos_signing_plan(path: Path) -> dict[str, object]:
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > MAX_PLAN_BYTES
        ):
            raise MacOSSigningPlanError("signing plan is invalid")
        value = json.loads(path.read_text(encoding="ascii"))
    except MacOSSigningPlanError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MacOSSigningPlanError("signing plan is invalid") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise MacOSSigningPlanError("signing plan is invalid")
    targets = value.get("targets")
    if not isinstance(targets, list):
        raise MacOSSigningPlanError("signing plan is invalid")
    native_targets = sorted(
        (
            target
            for target in targets
            if isinstance(target, dict) and target.get("kind") == "macho"
        ),
        key=lambda target: str(target.get("path")),
    )
    expected = signing_plan_from_inventory(
        {
            "schema": "quotabot.signing-inventory.v1",
            "platform": "macos",
            "surface": value.get("surface"),
            "architecture": value.get("architecture"),
            "candidate_sha256": value.get("candidate_sha256"),
            "inventory_sha256": value.get("inventory_sha256"),
            "native_code_count": len(native_targets),
            "native_code": [
                {
                    "path": target.get("path"),
                    "kind": "macho",
                }
                for target in native_targets
            ],
        }
    )
    if expected != value:
        raise MacOSSigningPlanError("signing plan is invalid")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate a macOS candidate and publish its exact signing plan."
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--surface", required=True, choices=("cli", "desktop"))
    parser.add_argument("--architecture", required=True, choices=("x64", "arm64"))
    parser.add_argument("root", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    try:
        plan = create_macos_signing_plan(
            args.root,
            manifest_path=args.manifest,
            output_path=args.output,
            surface=args.surface,
            architecture=args.architecture,
        )
    except MacOSSigningPlanError as error:
        print(
            json.dumps(
                {
                    "schema": ERROR_SCHEMA,
                    "ok": False,
                    "error": str(error),
                },
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 1
    digest = canonical_macos_signing_plan_sha256(plan)
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "surface": args.surface,
                "architecture": args.architecture,
                "target_count": plan["target_count"],
                "plan_sha256": digest,
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
