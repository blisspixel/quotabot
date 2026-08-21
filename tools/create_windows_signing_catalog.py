#!/usr/bin/env python3
"""Create an exact Azure Artifact Signing catalog from a trusted inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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


SCHEMA = "quotabot.windows-signing-catalog.v1"
ERROR_SCHEMA = "quotabot.windows-signing-catalog-error.v1"
MAX_CATALOG_BYTES = 1024 * 1024
_SHA256 = re.compile(r"^[0-9a-f]{64}$")

_ERROR_MESSAGES = {
    "inventory_invalid": "unsigned inventory cannot be validated",
    "candidate_changed": "candidate does not match the complete unsigned inventory",
    "catalog_path_invalid": "signing catalog output path is invalid",
    "catalog_output_failed": "signing catalog could not be published safely",
}


class WindowsSigningCatalogError(ValueError):
    """A bounded, path-private signing catalog failure."""

    def __init__(self, code: str):
        if code not in _ERROR_MESSAGES:
            raise ValueError(f"unknown signing catalog error code: {code}")
        self.code = code
        super().__init__(code)

    def __str__(self) -> str:
        return _ERROR_MESSAGES[self.code]


def _catalog_lines(
    inventory: dict[str, object],
    *,
    root_name: str,
    surface: str,
    architecture: str,
) -> tuple[str, ...]:
    if (
        inventory.get("schema") != "quotabot.signing-inventory.v1"
        or inventory.get("platform") != "windows"
        or inventory.get("surface") != surface
        or inventory.get("architecture") != architecture
        or not root_name
        or root_name in {".", ".."}
        or "/" in root_name
        or "\\" in root_name
        or any(ord(character) < 32 or ord(character) == 127 for character in root_name)
    ):
        raise WindowsSigningCatalogError("inventory_invalid")
    entries = inventory.get("native_code")
    if (
        not isinstance(entries, list)
        or not entries
        or len(entries) > MAX_NATIVE_CODE
        or inventory.get("native_code_count") != len(entries)
    ):
        raise WindowsSigningCatalogError("inventory_invalid")

    seen: set[str] = set()
    lines: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise WindowsSigningCatalogError("inventory_invalid")
        relative = entry.get("path")
        if not isinstance(relative, str):
            raise WindowsSigningCatalogError("inventory_invalid")
        parsed = PurePosixPath(relative)
        if (
            not relative
            or relative.startswith("/")
            or "\\" in relative
            or parsed.is_absolute()
            or any(part in {"", ".", ".."} for part in parsed.parts)
            or any(
                ord(character) < 32 or ord(character) == 127 for character in relative
            )
            or relative in seen
            or entry.get("kind") != "pe"
            or entry.get("architecture") != architecture
            or not isinstance(entry.get("bytes"), int)
            or isinstance(entry.get("bytes"), bool)
            or int(entry["bytes"]) <= 0
            or not isinstance(entry.get("sha256"), str)
            or _SHA256.fullmatch(str(entry["sha256"])) is None
        ):
            raise WindowsSigningCatalogError("inventory_invalid")
        seen.add(relative)
        lines.append(f"./{root_name}/{relative}")
    if lines != sorted(lines):
        raise WindowsSigningCatalogError("inventory_invalid")
    return tuple(lines)


def _validated_output_path(output: Path, *, candidate_root: Path) -> Path:
    try:
        resolved_root = candidate_root.resolve(strict=True)
        requested = Path(output)
        parent = requested.parent.resolve(strict=True)
        if parent != resolved_root.parent or requested.name in {"", ".", ".."}:
            raise WindowsSigningCatalogError("catalog_path_invalid")
        if any(
            ord(character) < 32 or ord(character) == 127 for character in requested.name
        ):
            raise WindowsSigningCatalogError("catalog_path_invalid")
        if requested.exists() or requested.is_symlink():
            metadata = requested.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise WindowsSigningCatalogError("catalog_path_invalid")
        resolved_output = parent / requested.name
        try:
            resolved_output.relative_to(resolved_root)
        except ValueError:
            pass
        else:
            raise WindowsSigningCatalogError("catalog_path_invalid")
        return resolved_output
    except WindowsSigningCatalogError:
        raise
    except (OSError, RuntimeError) as error:
        raise WindowsSigningCatalogError("catalog_path_invalid") from error


def _publish_catalog(path: Path, payload: bytes) -> None:
    if not payload or len(payload) > MAX_CATALOG_BYTES:
        raise WindowsSigningCatalogError("catalog_output_failed")
    descriptor = -1
    temporary: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
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
            raise WindowsSigningCatalogError("catalog_output_failed")
        if path.read_bytes() != payload:
            raise WindowsSigningCatalogError("catalog_output_failed")
    except WindowsSigningCatalogError:
        raise
    except OSError as error:
        raise WindowsSigningCatalogError("catalog_output_failed") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def create_windows_signing_catalog(
    root: Path,
    *,
    manifest_path: Path,
    output_path: Path,
    surface: str,
    architecture: str,
) -> tuple[str, ...]:
    """Validate an unsigned candidate and publish its exact PE signing catalog."""
    try:
        expected = load_inventory_manifest(manifest_path)
        current = inventory_native_code(
            root,
            platform="windows",
            surface=surface,
            architecture=architecture,
        ).to_dict()
    except NativeInventoryError as error:
        raise WindowsSigningCatalogError("inventory_invalid") from error
    if expected != current:
        raise WindowsSigningCatalogError("candidate_changed")

    output = _validated_output_path(output_path, candidate_root=Path(root))
    lines = _catalog_lines(
        expected,
        root_name=Path(root).resolve(strict=True).name,
        surface=surface,
        architecture=architecture,
    )
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    _publish_catalog(output, payload)
    return lines


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Validate a complete unsigned Windows candidate and publish the exact "
            "relative PE catalog consumed by Azure Artifact Signing."
        )
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
        lines = create_windows_signing_catalog(
            args.root,
            manifest_path=args.manifest,
            output_path=args.output,
            surface=args.surface,
            architecture=args.architecture,
        )
        digest = hashlib.sha256(("\n".join(lines) + "\n").encode("utf-8")).hexdigest()
    except WindowsSigningCatalogError as error:
        print(
            json.dumps(
                {
                    "schema": ERROR_SCHEMA,
                    "ok": False,
                    "code": error.code,
                    "error": str(error),
                },
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 1
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "surface": args.surface,
                "architecture": args.architecture,
                "native_code_count": len(lines),
                "catalog_sha256": digest,
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
