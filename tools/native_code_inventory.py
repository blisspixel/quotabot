#!/usr/bin/env python3
"""Inventory and compare native release candidates without mutation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
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

_MACH_ARCHITECTURES = {
    0x00000007: "x86",
    0x01000007: "x64",
    0x0000000C: "arm",
    0x0100000C: "arm64",
}
_MACH_ARCHITECTURE_ORDER = {"x86": 0, "x64": 1, "arm": 2, "arm64": 3}
_MAX_FAT_ARCHITECTURES = 16


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
    candidate_entries: tuple[dict[str, object], ...]
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
            "candidate_entry_count": len(self.candidate_entries),
            "candidate_entries": [dict(entry) for entry in self.candidate_entries],
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
    mode: int


@dataclass(frozen=True)
class _LinkSnapshot:
    path: Path
    relative: str
    target: str
    modified_ns: int
    device: int
    inode: int


@dataclass(frozen=True)
class _DirectorySnapshot:
    path: Path
    relative: str
    mode: int
    modified_ns: int
    device: int
    inode: int


def canonical_sha256(value: object) -> str:
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


def _validated_macos_link_target(relative: str, target: str) -> str:
    if (
        not target
        or len(target) > MAX_RELATIVE_PATH_CHARS
        or target.startswith("/")
        or "\\" in target
        or any(ord(character) < 32 or ord(character) == 127 for character in target)
    ):
        raise NativeInventoryError(
            f"macOS candidate contains an unsafe symbolic link: {relative}"
        )
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), target))
    if resolved in {"", ".", ".."} or resolved.startswith("../"):
        raise NativeInventoryError(
            f"macOS candidate contains an escaping symbolic link: {relative}"
        )
    return target


def _candidate_entries(root: Path, platform: str):
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
                if platform == "windows":
                    raise NativeInventoryError(
                        f"Windows candidate contains a symbolic link: {relative}"
                    )
                try:
                    target = _validated_macos_link_target(relative, os.readlink(path))
                except NativeInventoryError:
                    raise
                except OSError as error:
                    raise NativeInventoryError(
                        f"candidate path cannot be inspected: {relative}"
                    ) from error
                yield "symlink", path, relative, metadata, target
                continue
            if _is_junction(path, relative):
                raise NativeInventoryError(
                    f"{platform.capitalize()} candidate contains a junction: {relative}"
                )
            if stat.S_ISDIR(metadata.st_mode):
                child_directories.append(path)
                yield "directory", path, relative, metadata, None
            elif stat.S_ISREG(metadata.st_mode):
                yield "file", path, relative, metadata, None
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
            mode=stat.S_IMODE(expected.st_mode),
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


def _macho_architectures(payload: bytes, size: int) -> tuple[str, ...] | None:
    if len(payload) < 4:
        return None
    magic = payload[:4]
    thin = {
        b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xcf\xfa\xed\xfe": ("<", 32),
        b"\xfe\xed\xfa\xce": (">", 28),
        b"\xfe\xed\xfa\xcf": (">", 32),
    }.get(magic)
    if thin is not None:
        endian, header_size = thin
        if len(payload) < header_size or size < header_size:
            raise ValueError("truncated Mach-O header")
        cpu_type, _subtype, file_type, command_count, command_bytes = (
            struct.unpack_from(f"{endian}IIIII", payload, 4)
        )
        if file_type == 0 or command_count > 4096 or command_bytes > size - header_size:
            raise ValueError("invalid Mach-O header")
        architecture = _MACH_ARCHITECTURES.get(cpu_type, f"cpu-0x{cpu_type:08x}")
        return (architecture,)

    fat = {
        b"\xca\xfe\xba\xbe": (">", False),
        b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True),
        b"\xbf\xba\xfe\xca": ("<", True),
    }.get(magic)
    if fat is None:
        return None
    endian, is_64_bit = fat
    if len(payload) < 8:
        raise ValueError("truncated universal Mach-O header")
    architecture_count = struct.unpack_from(f"{endian}I", payload, 4)[0]
    entry_size = 32 if is_64_bit else 20
    table_end = 8 + architecture_count * entry_size
    if (
        architecture_count == 0
        or architecture_count > _MAX_FAT_ARCHITECTURES
        or table_end > len(payload)
        or table_end > size
    ):
        raise ValueError("invalid universal Mach-O table")
    architectures: list[str] = []
    slices: list[tuple[int, int]] = []
    for index in range(architecture_count):
        offset = 8 + index * entry_size
        if is_64_bit:
            cpu_type, _subtype, slice_offset, slice_size, alignment, _reserved = (
                struct.unpack_from(f"{endian}IIQQII", payload, offset)
            )
        else:
            cpu_type, _subtype, slice_offset, slice_size, alignment = (
                struct.unpack_from(f"{endian}IIIII", payload, offset)
            )
        if (
            slice_offset < table_end
            or slice_size == 0
            or slice_offset + slice_size > size
            or alignment > 31
        ):
            raise ValueError("invalid universal Mach-O slice")
        architecture = _MACH_ARCHITECTURES.get(cpu_type, f"cpu-0x{cpu_type:08x}")
        if architecture in architectures:
            raise ValueError("duplicate universal Mach-O architecture")
        architectures.append(architecture)
        slices.append((slice_offset, slice_offset + slice_size))
    sorted_slices = sorted(slices)
    for index, (start, end) in enumerate(sorted_slices):
        if index and start < sorted_slices[index - 1][1]:
            raise ValueError("overlapping universal Mach-O slices")
        if end <= start:
            raise ValueError("invalid universal Mach-O slice")
    return tuple(
        sorted(
            architectures,
            key=lambda value: (_MACH_ARCHITECTURE_ORDER.get(value, 99), value),
        )
    )


def _verify_stable_snapshot(
    root: Path,
    files: list[_FileSnapshot],
    links: list[_LinkSnapshot],
    directories: list[_DirectorySnapshot],
    *,
    platform: str,
) -> None:
    observed_files: set[str] = set()
    observed_links: dict[str, str] = {}
    observed_directories: set[str] = set()
    for kind, _path, relative, _metadata, target in _candidate_entries(root, platform):
        if kind == "file":
            observed_files.add(relative)
        elif kind == "symlink" and target is not None:
            observed_links[relative] = target
        elif kind == "directory":
            observed_directories.add(relative)
    expected_files = {item.relative for item in files}
    expected_links = {item.relative: item.target for item in links}
    expected_directories = {item.relative for item in directories}
    if (
        observed_files != expected_files
        or observed_links != expected_links
        or observed_directories != expected_directories
    ):
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
            or stat.S_IMODE(current.st_mode) != item.mode
            or (item.device and current.st_dev and current.st_dev != item.device)
            or (item.inode and current.st_ino and current.st_ino != item.inode)
        ):
            raise NativeInventoryError(
                f"candidate contents changed while inventoried: {item.relative}"
            )
    for item in links:
        try:
            current = item.path.lstat()
            target = os.readlink(item.path)
        except OSError as error:
            raise NativeInventoryError(
                f"candidate contents changed while inventoried: {item.relative}"
            ) from error
        if (
            not stat.S_ISLNK(current.st_mode)
            or target != item.target
            or current.st_mtime_ns != item.modified_ns
            or (item.device and current.st_dev and current.st_dev != item.device)
            or (item.inode and current.st_ino and current.st_ino != item.inode)
        ):
            raise NativeInventoryError(
                f"candidate contents changed while inventoried: {item.relative}"
            )
    for item in directories:
        try:
            current = item.path.lstat()
        except OSError as error:
            raise NativeInventoryError(
                f"candidate contents changed while inventoried: {item.relative}"
            ) from error
        if (
            not stat.S_ISDIR(current.st_mode)
            or stat.S_IMODE(current.st_mode) != item.mode
            or current.st_mtime_ns != item.modified_ns
            or (item.device and current.st_dev and current.st_dev != item.device)
            or (item.inode and current.st_ino and current.st_ino != item.inode)
        ):
            raise NativeInventoryError(
                f"candidate contents changed while inventoried: {item.relative}"
            )


def _is_expected_macho(relative: str, *, required: str) -> bool:
    if relative == required or relative.casefold().endswith(".dylib"):
        return True
    parts = relative.split("/")
    if "Contents" in parts:
        for index in range(len(parts) - 2):
            if parts[index] == "Contents" and parts[index + 1] == "MacOS":
                return True
    for index, part in enumerate(parts):
        if not part.casefold().endswith(".framework"):
            continue
        framework_name = part[: -len(".framework")]
        if parts[-1] == framework_name and "Resources" not in parts[index + 1 :]:
            return True
    return False


def inventory_native_code(
    root: Path,
    *,
    platform: str,
    surface: str,
    architecture: str,
) -> NativeInventory:
    """Return a deterministic native-code inventory for an existing candidate."""
    if platform not in {"windows", "macos"}:
        raise NativeInventoryError("platform must be windows or macos")
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
    link_snapshots: list[_LinkSnapshot] = []
    directory_snapshots: list[_DirectorySnapshot] = []
    candidate_file_count = 0
    candidate_bytes = 0

    for kind, path, relative, metadata, link_target in _candidate_entries(
        resolved, platform
    ):
        folded = relative.casefold()
        previous = seen_paths.get(folded)
        if previous is not None and previous != relative:
            raise NativeInventoryError(
                f"candidate contains case-colliding paths: {previous}, {relative}"
            )
        seen_paths[folded] = relative
        if kind == "symlink":
            assert link_target is not None
            candidate_records.append(
                {"path": relative, "kind": "symlink", "link_target": link_target}
            )
            link_snapshots.append(
                _LinkSnapshot(
                    path=path,
                    relative=relative,
                    target=link_target,
                    modified_ns=metadata.st_mtime_ns,
                    device=metadata.st_dev,
                    inode=metadata.st_ino,
                )
            )
            continue
        if kind == "directory":
            candidate_records.append(
                {
                    "path": relative,
                    "kind": "directory",
                    "mode": stat.S_IMODE(metadata.st_mode),
                }
            )
            directory_snapshots.append(
                _DirectorySnapshot(
                    path=path,
                    relative=relative,
                    mode=stat.S_IMODE(metadata.st_mode),
                    modified_ns=metadata.st_mtime_ns,
                    device=metadata.st_dev,
                    inode=metadata.st_ino,
                )
            )
            continue
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
                "kind": "file",
                "bytes": metadata.st_size,
                "mode": stat.S_IMODE(metadata.st_mode),
                "sha256": digest,
            }
        )
        if platform == "windows":
            pe_architecture = _pe_architecture(captured, metadata.st_size)
            observed_architectures = (
                (pe_architecture,) if pe_architecture is not None else None
            )
            expected_native = path.suffix.casefold() in {".dll", ".exe"}
            malformed_label = "PE module"
            kind_label = "pe"
        else:
            try:
                observed_architectures = _macho_architectures(
                    captured, metadata.st_size
                )
            except ValueError as error:
                raise NativeInventoryError(
                    f"expected Mach-O module is malformed: {relative}"
                ) from error
            required_macos = (
                "bin/quotabot"
                if surface == "cli"
                else "quotabot.app/Contents/MacOS/quotabot"
            )
            expected_native = _is_expected_macho(relative, required=required_macos)
            malformed_label = "Mach-O module"
            kind_label = "macho"
        if expected_native and observed_architectures is None:
            raise NativeInventoryError(
                f"expected {malformed_label} is malformed: {relative}"
            )
        if observed_architectures is not None:
            observed_architecture = "+".join(observed_architectures)
            if architecture not in observed_architectures:
                platform_label = "PE" if platform == "windows" else "Mach-O"
                raise NativeInventoryError(
                    f"{platform_label} architecture mismatch at {relative}: expected "
                    f"{architecture}, observed {observed_architecture}"
                )
            native_entries.append(
                NativeCodeEntry(
                    path=relative,
                    kind=kind_label,
                    architecture=observed_architecture,
                    bytes=metadata.st_size,
                    sha256=digest,
                )
            )
            if len(native_entries) > MAX_NATIVE_CODE:
                raise NativeInventoryError(
                    "candidate contains too many native code files"
                )

    if platform == "windows":
        required = "bin/quotabot.exe" if surface == "cli" else "quotabot.exe"
        required_label = "PE module"
    else:
        required = (
            "bin/quotabot"
            if surface == "cli"
            else "quotabot.app/Contents/MacOS/quotabot"
        )
        required_label = "Mach-O module"
    candidate_paths = {record["path"] for record in candidate_records}
    if required not in candidate_paths:
        raise NativeInventoryError(
            f"required {required_label} launcher is missing: {required}"
        )
    native_code = tuple(sorted(native_entries, key=lambda entry: entry.path))
    if required not in {entry.path for entry in native_code}:
        raise NativeInventoryError(
            f"expected {required_label} is malformed: {required}"
        )

    _verify_stable_snapshot(
        resolved,
        snapshots,
        link_snapshots,
        directory_snapshots,
        platform=platform,
    )
    candidate_records.sort(key=lambda record: str(record["path"]))
    candidate_sha256 = canonical_sha256(candidate_records)
    body = {
        "schema": SCHEMA,
        "platform": platform,
        "surface": surface,
        "architecture": architecture,
        "candidate_file_count": candidate_file_count,
        "candidate_bytes": candidate_bytes,
        "candidate_sha256": candidate_sha256,
        "candidate_entry_count": len(candidate_records),
        "candidate_entries": candidate_records,
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
        candidate_entries=tuple(candidate_records),
        native_code=native_code,
        inventory_sha256=canonical_sha256(body),
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


def load_inventory_manifest(path: Path) -> dict[str, object]:
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
        description="Inventory native code in an existing release candidate.",
    )
    parser.add_argument("--platform", required=True, choices=("windows", "macos"))
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
            expected = load_inventory_manifest(args.expect_manifest)
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
    kind = "PE" if inventory.platform == "windows" else "Mach-O"
    print(
        f"native signing inventory {inventory.platform}/{inventory.surface}/"
        f"{inventory.architecture}: {inventory.native_code_count} {kind} modules, "
        f"{inventory.candidate_file_count} candidate files"
    )
    print(f"candidate sha256: {inventory.candidate_sha256}")
    print(f"inventory sha256: {inventory.inventory_sha256}")
    for entry in inventory.native_code:
        print(f"{entry.kind} {entry.architecture} {entry.sha256} {entry.path}")
    if args.expect_manifest is not None:
        print("candidate matches expected inventory")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
