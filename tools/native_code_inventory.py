#!/usr/bin/env python3
"""Inventory and compare Windows PE release candidates without mutation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


SCHEMA = "quotabot.signing-inventory.v1"
MAX_CANDIDATE_ENTRIES = 20_000
MAX_CANDIDATE_FILES = 20_000
MAX_CANDIDATE_BYTES = 2 * 1024 * 1024 * 1024
MAX_NATIVE_CODE = 512
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_RELATIVE_PATH_CHARS = 1024
MAX_PE_HEADER_OFFSET = 1024 * 1024
HEADER_CAPTURE_BYTES = MAX_PE_HEADER_OFFSET + 256

_PE_ARCHITECTURES = {
    0x014C: "x86",
    0x01C0: "arm",
    0x01C4: "arm",
    0x0200: "ia64",
    0x8664: "x64",
    0xAA64: "arm64",
}


class NativeInventoryError(ValueError):
    """Raised when a candidate cannot produce or match a trusted inventory."""


@dataclass(frozen=True)
class NativeCodeEntry:
    path: str
    kind: str
    architecture: str
    bytes: int
    sha256: str

    def to_dict(self) -> dict[str, object]:
        return {
            "path": self.path,
            "kind": self.kind,
            "architecture": self.architecture,
            "bytes": self.bytes,
            "sha256": self.sha256,
        }


@dataclass(frozen=True)
class NativeInventory:
    schema: str
    platform: str
    surface: str
    architecture: str
    candidate_file_count: int
    candidate_bytes: int
    candidate_sha256: str
    native_code: tuple[NativeCodeEntry, ...]
    inventory_sha256: str

    @property
    def native_code_count(self) -> int:
        return len(self.native_code)

    def to_dict(self) -> dict[str, object]:
        return {
            "schema": self.schema,
            "platform": self.platform,
            "surface": self.surface,
            "architecture": self.architecture,
            "candidate_file_count": self.candidate_file_count,
            "candidate_bytes": self.candidate_bytes,
            "candidate_sha256": self.candidate_sha256,
            "native_code_count": self.native_code_count,
            "native_code": [entry.to_dict() for entry in self.native_code],
            "inventory_sha256": self.inventory_sha256,
        }


@dataclass(frozen=True)
class _FileSnapshot:
    path: Path
    relative: str
    size: int
    modified_ns: int
    device: int
    inode: int


def _canonical_sha256(value: object) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    return hashlib.sha256(encoded).hexdigest()


def _relative_path(root: Path, path: Path) -> str:
    relative = path.relative_to(root).as_posix()
    if not relative or relative == ".":
        raise NativeInventoryError("candidate contains an invalid empty path")
    if len(relative) > MAX_RELATIVE_PATH_CHARS:
        raise NativeInventoryError("candidate path exceeds the length limit")
    if any(ord(character) < 32 or ord(character) == 127 for character in relative):
        raise NativeInventoryError("candidate path contains a control character")
    return relative


def _is_junction(path: Path, relative: str) -> bool:
    predicate = getattr(path, "is_junction", None)
    if predicate is None:
        return False
    try:
        return bool(predicate())
    except OSError as error:
        raise NativeInventoryError(
            f"candidate path cannot be inspected: {relative}"
        ) from error


def _candidate_entries(root: Path):
    entry_count = 0
    directories = [root]
    while directories:
        directory = directories.pop()
        names: list[str] = []
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    entry_count += 1
                    if entry_count > MAX_CANDIDATE_ENTRIES:
                        raise NativeInventoryError(
                            "candidate contains too many entries"
                        )
                    names.append(entry.name)
        except NativeInventoryError:
            raise
        except OSError as error:
            raise NativeInventoryError("candidate tree cannot be read") from error

        child_directories: list[Path] = []
        for name in sorted(names):
            path = directory / name
            relative = _relative_path(root, path)
            try:
                metadata = path.lstat()
            except OSError as error:
                raise NativeInventoryError(
                    f"candidate path cannot be inspected: {relative}"
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                raise NativeInventoryError(
                    f"Windows candidate contains a symbolic link: {relative}"
                )
            if _is_junction(path, relative):
                raise NativeInventoryError(
                    f"Windows candidate contains a junction: {relative}"
                )
            if stat.S_ISDIR(metadata.st_mode):
                child_directories.append(path)
                yield "directory", path, relative, metadata
            elif stat.S_ISREG(metadata.st_mode):
                yield "file", path, relative, metadata
            else:
                raise NativeInventoryError(
                    f"candidate contains a special file: {relative}"
                )
        directories.extend(reversed(child_directories))


def _same_identity(expected: os.stat_result, observed: os.stat_result) -> bool:
    if (
        not stat.S_ISREG(observed.st_mode)
        or expected.st_size != observed.st_size
        or expected.st_mtime_ns != observed.st_mtime_ns
    ):
        return False
    if expected.st_dev and observed.st_dev and expected.st_dev != observed.st_dev:
        return False
    if expected.st_ino and observed.st_ino and expected.st_ino != observed.st_ino:
        return False
    return True


def _hash_and_capture(
    path: Path,
    relative: str,
    expected: os.stat_result,
) -> tuple[str, bytes, _FileSnapshot]:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_BINARY", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise NativeInventoryError(
            f"candidate file cannot be opened for inventory: {relative}"
        ) from error
    digest = hashlib.sha256()
    captured = bytearray()
    try:
        opened = os.fstat(descriptor)
        if not _same_identity(expected, opened):
            raise NativeInventoryError(
                f"candidate file changed before read: {relative}"
            )
        remaining = opened.st_size
        while remaining:
            try:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
            except OSError as error:
                raise NativeInventoryError(
                    f"candidate file cannot be read: {relative}"
                ) from error
            if not chunk:
                raise NativeInventoryError(
                    f"candidate file changed while read: {relative}"
                )
            remaining -= len(chunk)
            digest.update(chunk)
            if len(captured) < HEADER_CAPTURE_BYTES:
                capture_remaining = HEADER_CAPTURE_BYTES - len(captured)
                captured.extend(chunk[:capture_remaining])
        try:
            extra = os.read(descriptor, 1)
            after = os.fstat(descriptor)
        except OSError as error:
            raise NativeInventoryError(
                f"candidate file cannot be finalized: {relative}"
            ) from error
        if extra or not _same_identity(opened, after):
            raise NativeInventoryError(f"candidate file changed while read: {relative}")
    finally:
        os.close(descriptor)
    return (
        digest.hexdigest(),
        bytes(captured),
        _FileSnapshot(
            path=path,
            relative=relative,
            size=expected.st_size,
            modified_ns=expected.st_mtime_ns,
            device=expected.st_dev,
            inode=expected.st_ino,
        ),
    )


def _pe_architecture(payload: bytes, size: int) -> str | None:
    if len(payload) < 0x40 or payload[:2] != b"MZ":
        return None
    header_offset = struct.unpack_from("<I", payload, 0x3C)[0]
    if (
        header_offset < 0x40
        or header_offset > MAX_PE_HEADER_OFFSET
        or header_offset + 26 > size
        or header_offset + 26 > len(payload)
        or payload[header_offset : header_offset + 4] != b"PE\x00\x00"
    ):
        return None
    machine, sections = struct.unpack_from("<HH", payload, header_offset + 4)
    optional_size, characteristics = struct.unpack_from(
        "<HH", payload, header_offset + 20
    )
    optional_magic = struct.unpack_from("<H", payload, header_offset + 24)[0]
    minimum_optional_size = {0x10B: 96, 0x20B: 112}.get(optional_magic)
    if (
        sections == 0
        or sections > 96
        or minimum_optional_size is None
        or optional_size < minimum_optional_size
        or characteristics & 0x0002 == 0
        or header_offset + 24 + optional_size + (sections * 40) > size
    ):
        return None
    size_of_image, size_of_headers = struct.unpack_from(
        "<II", payload, header_offset + 24 + 56
    )
    if size_of_image == 0 or size_of_headers == 0 or size_of_headers > size:
        return None
    return _PE_ARCHITECTURES.get(machine, f"machine-0x{machine:04x}")


def _verify_stable_snapshot(root: Path, files: list[_FileSnapshot]) -> None:
    observed_files: set[str] = set()
    for kind, _path, relative, _metadata in _candidate_entries(root):
        if kind == "file":
            observed_files.add(relative)
    expected_files = {item.relative for item in files}
    if observed_files != expected_files:
        raise NativeInventoryError("candidate contents changed while inventoried")
    for item in files:
        try:
            current = item.path.lstat()
        except OSError as error:
            raise NativeInventoryError(
                f"candidate contents changed while inventoried: {item.relative}"
            ) from error
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_size != item.size
            or current.st_mtime_ns != item.modified_ns
            or (item.device and current.st_dev and current.st_dev != item.device)
            or (item.inode and current.st_ino and current.st_ino != item.inode)
        ):
            raise NativeInventoryError(
                f"candidate contents changed while inventoried: {item.relative}"
            )


def inventory_native_code(
    root: Path,
    *,
    platform: str,
    surface: str,
    architecture: str,
) -> NativeInventory:
    """Return a deterministic Windows PE inventory for an existing candidate."""
    if platform != "windows":
        raise NativeInventoryError("only Windows inventory is currently supported")
    if surface not in {"cli", "desktop"}:
        raise NativeInventoryError("surface must be cli or desktop")
    if architecture not in {"x64", "arm64"}:
        raise NativeInventoryError("architecture must be x64 or arm64")
    requested = Path(root)
    try:
        if requested.is_symlink() or _is_junction(requested, "candidate root"):
            raise NativeInventoryError("candidate root must not be a link or junction")
        resolved = requested.resolve(strict=True)
    except NativeInventoryError:
        raise
    except (OSError, RuntimeError) as error:
        raise NativeInventoryError("candidate root does not exist") from error
    if not resolved.is_dir():
        raise NativeInventoryError("candidate root is not a directory")

    seen_paths: dict[str, str] = {}
    candidate_records: list[dict[str, object]] = []
    native_entries: list[NativeCodeEntry] = []
    snapshots: list[_FileSnapshot] = []
    candidate_file_count = 0
    candidate_bytes = 0

    for kind, path, relative, metadata in _candidate_entries(resolved):
        folded = relative.casefold()
        previous = seen_paths.get(folded)
        if previous is not None and previous != relative:
            raise NativeInventoryError(
                f"candidate contains case-colliding paths: {previous}, {relative}"
            )
        seen_paths[folded] = relative
        if kind != "file":
            continue
        candidate_file_count += 1
        if candidate_file_count > MAX_CANDIDATE_FILES:
            raise NativeInventoryError("candidate contains too many files")
        candidate_bytes += metadata.st_size
        if candidate_bytes > MAX_CANDIDATE_BYTES:
            raise NativeInventoryError("candidate exceeds the byte limit")
        digest, captured, snapshot = _hash_and_capture(path, relative, metadata)
        snapshots.append(snapshot)
        candidate_records.append(
            {
                "path": relative,
                "bytes": metadata.st_size,
                "sha256": digest,
            }
        )
        observed_architecture = _pe_architecture(captured, metadata.st_size)
        if path.suffix.casefold() in {".dll", ".exe"} and observed_architecture is None:
            raise NativeInventoryError(f"expected PE module is malformed: {relative}")
        if observed_architecture is not None:
            if observed_architecture != architecture:
                raise NativeInventoryError(
                    f"PE architecture mismatch at {relative}: expected "
                    f"{architecture}, observed {observed_architecture}"
                )
            native_entries.append(
                NativeCodeEntry(
                    path=relative,
                    kind="pe",
                    architecture=observed_architecture,
                    bytes=metadata.st_size,
                    sha256=digest,
                )
            )
            if len(native_entries) > MAX_NATIVE_CODE:
                raise NativeInventoryError(
                    "candidate contains too many native code files"
                )

    required = "bin/quotabot.exe" if surface == "cli" else "quotabot.exe"
    candidate_paths = {record["path"] for record in candidate_records}
    if required not in candidate_paths:
        raise NativeInventoryError(f"required PE launcher is missing: {required}")
    native_code = tuple(sorted(native_entries, key=lambda entry: entry.path))
    if required not in {entry.path for entry in native_code}:
        raise NativeInventoryError(f"expected PE module is malformed: {required}")

    _verify_stable_snapshot(resolved, snapshots)
    candidate_records.sort(key=lambda record: str(record["path"]))
    candidate_sha256 = _canonical_sha256(candidate_records)
    body = {
        "schema": SCHEMA,
        "platform": platform,
        "surface": surface,
        "architecture": architecture,
        "candidate_file_count": candidate_file_count,
        "candidate_bytes": candidate_bytes,
        "candidate_sha256": candidate_sha256,
        "native_code_count": len(native_code),
        "native_code": [entry.to_dict() for entry in native_code],
    }
    return NativeInventory(
        schema=SCHEMA,
        platform=platform,
        surface=surface,
        architecture=architecture,
        candidate_file_count=candidate_file_count,
        candidate_bytes=candidate_bytes,
        candidate_sha256=candidate_sha256,
        native_code=native_code,
        inventory_sha256=_canonical_sha256(body),
    )


def _read_manifest_bytes(path: Path) -> bytes:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_MANIFEST_BYTES:
            raise NativeInventoryError("expected inventory manifest is invalid")
        flags = os.O_RDONLY
        flags |= getattr(os, "O_BINARY", 0)
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
    except NativeInventoryError:
        raise
    except OSError as error:
        raise NativeInventoryError("expected inventory manifest is invalid") from error
    payload = bytearray()
    try:
        opened = os.fstat(descriptor)
        if not _same_identity(metadata, opened) or opened.st_size > MAX_MANIFEST_BYTES:
            raise NativeInventoryError("expected inventory manifest is invalid")
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                raise NativeInventoryError("expected inventory manifest is invalid")
            payload.extend(chunk)
            remaining -= len(chunk)
        extra = os.read(descriptor, 1)
        after = os.fstat(descriptor)
        if extra or not _same_identity(opened, after):
            raise NativeInventoryError("expected inventory manifest is invalid")
    except OSError as error:
        raise NativeInventoryError("expected inventory manifest is invalid") from error
    finally:
        os.close(descriptor)
    return bytes(payload)


def _expected_manifest(path: Path) -> dict[str, object]:
    try:
        value = json.loads(_read_manifest_bytes(path).decode("utf-8"))
    except NativeInventoryError:
        raise
    except (UnicodeError, json.JSONDecodeError) as error:
        raise NativeInventoryError("expected inventory manifest is invalid") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise NativeInventoryError("expected inventory manifest is invalid")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inventory Windows PE code in an existing release candidate.",
    )
    parser.add_argument("--platform", required=True, choices=("windows",))
    parser.add_argument("--surface", required=True, choices=("cli", "desktop"))
    parser.add_argument("--architecture", required=True, choices=("x64", "arm64"))
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", dest="as_json")
    output.add_argument("--expect-manifest", type=Path)
    parser.add_argument("root", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    try:
        inventory = inventory_native_code(
            args.root,
            platform=args.platform,
            surface=args.surface,
            architecture=args.architecture,
        )
        if args.expect_manifest is not None:
            expected = _expected_manifest(args.expect_manifest)
            if expected != inventory.to_dict():
                raise NativeInventoryError(
                    "candidate changed after inventory: expected candidate or "
                    "native-code digest does not match"
                )
    except NativeInventoryError as error:
        print(f"native signing inventory failed: {error}", file=sys.stderr)
        return 1
    except (OSError, RuntimeError):
        print(
            "native signing inventory failed: candidate cannot be inspected",
            file=sys.stderr,
        )
        return 1
    if args.as_json:
        print(
            json.dumps(
                inventory.to_dict(),
                ensure_ascii=True,
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 0
    print(
        f"native signing inventory {inventory.platform}/{inventory.surface}/"
        f"{inventory.architecture}: {inventory.native_code_count} PE modules, "
        f"{inventory.candidate_file_count} candidate files"
    )
    print(f"candidate sha256: {inventory.candidate_sha256}")
    print(f"inventory sha256: {inventory.inventory_sha256}")
    for entry in inventory.native_code:
        print(f"pe {entry.architecture} {entry.sha256} {entry.path}")
    if args.expect_manifest is not None:
        print("candidate matches expected inventory")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
