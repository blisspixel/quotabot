#!/usr/bin/env python3
"""Validate the exact full-tree changes made by Windows signing."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import stat
import struct
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.create_windows_signing_catalog import MAX_CATALOG_BYTES  # noqa: E402
from tools.native_code_inventory import (  # noqa: E402
    MAX_CANDIDATE_BYTES,
    MAX_CANDIDATE_ENTRIES,
    MAX_CANDIDATE_FILES,
    MAX_NATIVE_CODE,
    MAX_RELATIVE_PATH_CHARS,
    NativeInventoryError,
    canonical_sha256,
    inventory_native_code,
    load_inventory_manifest,
)


SCHEMA = "quotabot.windows-signing-delta.v1"
ERROR_SCHEMA = "quotabot.windows-signing-delta-error.v1"
MAX_RECEIPT_BYTES = 128 * 1024
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_INVENTORY_KEYS = {
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
_ERROR_CODES = {
    "candidate_unchanged",
    "catalog_invalid",
    "catalog_mismatch",
    "content_changed_outside_catalog",
    "inventory_invalid",
    "input_unstable",
    "kind_changed",
    "link_target_changed",
    "mode_changed",
    "native_metadata_invalid",
    "native_set_changed",
    "pe_authenticode_invalid",
    "pe_content_changed",
    "pe_invalid",
    "pe_layout_changed",
    "pe_preexisting_certificate",
    "path_added",
    "path_removed",
    "planned_native_unchanged",
    "receipt_path_invalid",
    "receipt_too_large",
    "receipt_write_failed",
    "root_metadata_mismatch",
    "root_invalid",
    "root_manifest_mismatch",
    "root_unstable",
    "scope_mismatch",
}

_MAX_PE_BYTES = 512 * 1024 * 1024
_MAX_PE_HEADER_OFFSET = 4 * 1024 * 1024
_WIN_CERT_REVISION_2_0 = 0x0200
_WIN_CERT_TYPE_PKCS_SIGNED_DATA = 0x0002


@dataclass(frozen=True)
class _PeLayout:
    checksum_offset: int
    security_directory_offset: int
    certificate_offset: int
    certificate_size: int


class WindowsSigningDeltaError(ValueError):
    """A bounded, path-private Windows candidate-delta failure."""

    def __init__(self, code: str):
        if code not in _ERROR_CODES:
            raise ValueError(f"unknown Windows signing delta error code: {code}")
        self.code = code
        super().__init__(code)


def _integer(value: object, *, minimum: int, maximum: int) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < minimum or value > maximum:
        return None
    return value


def _relative_path(value: object, *, error_code: str) -> str:
    if not isinstance(value, str):
        raise WindowsSigningDeltaError(error_code)
    parsed = PurePosixPath(value)
    if (
        not value
        or len(value) > MAX_RELATIVE_PATH_CHARS
        or value.startswith("/")
        or "\\" in value
        or parsed.is_absolute()
        or parsed.as_posix() != value
        or any(part in {"", ".", ".."} for part in parsed.parts)
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise WindowsSigningDeltaError(error_code)
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
        raise WindowsSigningDeltaError("inventory_invalid")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), value))
    if resolved in {"", ".", ".."} or resolved.startswith("../"):
        raise WindowsSigningDeltaError("inventory_invalid")
    return value


def validated_windows_inventory(value: dict[str, object]) -> dict[str, object]:
    """Validate a complete canonical Windows signing inventory."""
    if (
        set(value) != _INVENTORY_KEYS
        or value.get("schema") != "quotabot.signing-inventory.v1"
        or value.get("platform") != "windows"
        or value.get("surface") not in {"cli", "desktop"}
        or value.get("architecture") not in {"x64", "arm64"}
    ):
        raise WindowsSigningDeltaError("inventory_invalid")

    entries = value.get("candidate_entries")
    native_code = value.get("native_code")
    if (
        not isinstance(entries, list)
        or not isinstance(native_code, list)
        or not entries
        or not native_code
        or len(entries) > MAX_CANDIDATE_ENTRIES
        or len(native_code) > MAX_NATIVE_CODE
        or value.get("candidate_entry_count") != len(entries)
        or value.get("native_code_count") != len(native_code)
    ):
        raise WindowsSigningDeltaError("inventory_invalid")

    entry_paths: list[str] = []
    entry_by_path: dict[str, dict[str, object]] = {}
    file_count = 0
    candidate_bytes = 0
    for raw in entries:
        if not isinstance(raw, dict):
            raise WindowsSigningDeltaError("inventory_invalid")
        relative = _relative_path(raw.get("path"), error_code="inventory_invalid")
        kind = raw.get("kind")
        if kind == "file":
            if set(raw) != {"path", "kind", "bytes", "mode", "sha256"}:
                raise WindowsSigningDeltaError("inventory_invalid")
            size = _integer(raw.get("bytes"), minimum=0, maximum=MAX_CANDIDATE_BYTES)
            mode = _integer(raw.get("mode"), minimum=0, maximum=0o7777)
            digest = raw.get("sha256")
            if (
                size is None
                or mode is None
                or not isinstance(digest, str)
                or _SHA256.fullmatch(digest) is None
            ):
                raise WindowsSigningDeltaError("inventory_invalid")
            file_count += 1
            candidate_bytes += size
        elif kind == "directory":
            if (
                set(raw) != {"path", "kind", "mode"}
                or _integer(raw.get("mode"), minimum=0, maximum=0o7777) is None
            ):
                raise WindowsSigningDeltaError("inventory_invalid")
        elif kind == "symlink":
            if set(raw) != {"path", "kind", "link_target"}:
                raise WindowsSigningDeltaError("inventory_invalid")
            _link_target(raw.get("link_target"), relative=relative)
        else:
            raise WindowsSigningDeltaError("inventory_invalid")
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
        raise WindowsSigningDeltaError("inventory_invalid")

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
            raise WindowsSigningDeltaError("inventory_invalid")
        relative = _relative_path(raw.get("path"), error_code="inventory_invalid")
        size = _integer(raw.get("bytes"), minimum=1, maximum=MAX_CANDIDATE_BYTES)
        digest = raw.get("sha256")
        file_entry = entry_by_path.get(relative)
        if (
            raw.get("kind") != "pe"
            or raw.get("architecture") != requested_architecture
            or size is None
            or not isinstance(digest, str)
            or _SHA256.fullmatch(digest) is None
            or file_entry is None
            or file_entry.get("kind") != "file"
            or file_entry.get("bytes") != size
            or file_entry.get("sha256") != digest
        ):
            raise WindowsSigningDeltaError("inventory_invalid")
        native_paths.append(relative)
    if native_paths != sorted(native_paths) or len(set(native_paths)) != len(
        native_paths
    ):
        raise WindowsSigningDeltaError("inventory_invalid")

    body = {key: item for key, item in value.items() if key != "inventory_sha256"}
    digest = value.get("inventory_sha256")
    if (
        not isinstance(digest, str)
        or _SHA256.fullmatch(digest) is None
        or digest != canonical_sha256(body)
    ):
        raise WindowsSigningDeltaError("inventory_invalid")
    return value


def _load_inventory(path: Path) -> dict[str, object]:
    try:
        value = load_inventory_manifest(path)
    except NativeInventoryError as error:
        raise WindowsSigningDeltaError("inventory_invalid") from error
    return validated_windows_inventory(value)


def _read_catalog(path: Path) -> bytes:
    descriptor = -1
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > MAX_CATALOG_BYTES
        ):
            raise WindowsSigningDeltaError("catalog_invalid")
        flags = os.O_RDONLY
        flags |= getattr(os, "O_BINARY", 0)
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_size != metadata.st_size
            or opened.st_mtime_ns != metadata.st_mtime_ns
            or (metadata.st_dev and opened.st_dev and metadata.st_dev != opened.st_dev)
            or (metadata.st_ino and opened.st_ino and metadata.st_ino != opened.st_ino)
        ):
            raise WindowsSigningDeltaError("catalog_invalid")
        payload = bytearray()
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                raise WindowsSigningDeltaError("catalog_invalid")
            payload.extend(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise WindowsSigningDeltaError("catalog_invalid")
        after = os.fstat(descriptor)
        if (
            opened.st_size != after.st_size
            or opened.st_mtime_ns != after.st_mtime_ns
            or (opened.st_dev and after.st_dev and opened.st_dev != after.st_dev)
            or (opened.st_ino and after.st_ino and opened.st_ino != after.st_ino)
        ):
            raise WindowsSigningDeltaError("catalog_invalid")
        return bytes(payload)
    except WindowsSigningDeltaError:
        raise
    except OSError as error:
        raise WindowsSigningDeltaError("catalog_invalid") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _load_catalog(path: Path) -> tuple[tuple[str, ...], str]:
    payload = _read_catalog(path)
    try:
        text = payload.decode("ascii")
    except UnicodeError as error:
        raise WindowsSigningDeltaError("catalog_invalid") from error
    if not text.endswith("\n") or "\r" in text or "\x00" in text:
        raise WindowsSigningDeltaError("catalog_invalid")
    lines = text[:-1].split("\n")
    if not lines or any(not line for line in lines) or len(lines) > MAX_NATIVE_CODE:
        raise WindowsSigningDeltaError("catalog_invalid")

    root_name: str | None = None
    paths: list[str] = []
    for line in lines:
        if not line.startswith("./"):
            raise WindowsSigningDeltaError("catalog_invalid")
        root, separator, relative = line[2:].partition("/")
        if (
            not separator
            or not root
            or root in {".", ".."}
            or len(root) > MAX_RELATIVE_PATH_CHARS
            or "\\" in root
            or ":" in root
            or root != root.rstrip(" .")
            or any(ord(character) < 32 or ord(character) == 127 for character in root)
        ):
            raise WindowsSigningDeltaError("catalog_invalid")
        if root_name is None:
            root_name = root
        elif root != root_name:
            raise WindowsSigningDeltaError("catalog_invalid")
        paths.append(_relative_path(relative, error_code="catalog_invalid"))
    if (
        lines != sorted(lines)
        or len(set(paths)) != len(paths)
        or len({item.casefold() for item in paths}) != len(paths)
        or payload != ("\n".join(lines) + "\n").encode("ascii")
    ):
        raise WindowsSigningDeltaError("catalog_invalid")
    return tuple(paths), hashlib.sha256(payload).hexdigest()


def _inventory_root(
    root: Path,
    manifest: dict[str, object],
    *,
    stability_check: bool,
) -> dict[str, object]:
    try:
        current = inventory_native_code(
            root,
            platform="windows",
            surface=str(manifest["surface"]),
            architecture=str(manifest["architecture"]),
        ).to_dict()
    except (NativeInventoryError, OSError, RuntimeError) as error:
        code = "root_unstable" if stability_check else "root_invalid"
        raise WindowsSigningDeltaError(code) from error
    if current != manifest:
        code = "root_unstable" if stability_check else "root_manifest_mismatch"
        raise WindowsSigningDeltaError(code)
    return current


def _read_root_file(root: Path, relative: str) -> bytes:
    descriptor = -1
    try:
        resolved_root = root.resolve(strict=True)
        requested = resolved_root.joinpath(*PurePosixPath(relative).parts)
        metadata = requested.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > _MAX_PE_BYTES
        ):
            raise WindowsSigningDeltaError("pe_invalid")
        flags = os.O_RDONLY
        flags |= getattr(os, "O_BINARY", 0)
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(requested, flags)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_size != metadata.st_size
            or opened.st_mtime_ns != metadata.st_mtime_ns
            or (metadata.st_dev and opened.st_dev and metadata.st_dev != opened.st_dev)
            or (metadata.st_ino and opened.st_ino and metadata.st_ino != opened.st_ino)
        ):
            raise WindowsSigningDeltaError("root_unstable")
        payload = bytearray()
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise WindowsSigningDeltaError("root_unstable")
            payload.extend(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise WindowsSigningDeltaError("root_unstable")
        after = os.fstat(descriptor)
        if (
            after.st_size != opened.st_size
            or after.st_mtime_ns != opened.st_mtime_ns
            or (opened.st_dev and after.st_dev and opened.st_dev != after.st_dev)
            or (opened.st_ino and after.st_ino and opened.st_ino != after.st_ino)
        ):
            raise WindowsSigningDeltaError("root_unstable")
        return bytes(payload)
    except WindowsSigningDeltaError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise WindowsSigningDeltaError("root_unstable") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _parse_pe(payload: bytes) -> _PeLayout:
    try:
        if len(payload) < 0x40 or payload[:2] != b"MZ":
            raise WindowsSigningDeltaError("pe_invalid")
        header_offset = struct.unpack_from("<I", payload, 0x3C)[0]
        if (
            header_offset < 0x40
            or header_offset > _MAX_PE_HEADER_OFFSET
            or header_offset + 24 > len(payload)
            or payload[header_offset : header_offset + 4] != b"PE\x00\x00"
        ):
            raise WindowsSigningDeltaError("pe_invalid")
        sections = struct.unpack_from("<H", payload, header_offset + 6)[0]
        optional_size = struct.unpack_from("<H", payload, header_offset + 20)[0]
        optional_offset = header_offset + 24
        if (
            sections == 0
            or sections > 96
            or optional_offset + optional_size > len(payload)
        ):
            raise WindowsSigningDeltaError("pe_invalid")
        magic = struct.unpack_from("<H", payload, optional_offset)[0]
        if magic == 0x20B:
            data_directories_offset = optional_offset + 112
            directory_count_offset = optional_offset + 108
        elif magic == 0x10B:
            data_directories_offset = optional_offset + 96
            directory_count_offset = optional_offset + 92
        else:
            raise WindowsSigningDeltaError("pe_invalid")
        security_directory_offset = data_directories_offset + 4 * 8
        checksum_offset = optional_offset + 64
        section_table_end = optional_offset + optional_size + sections * 40
        if (
            directory_count_offset + 4 > optional_offset + optional_size
            or security_directory_offset + 8 > optional_offset + optional_size
            or checksum_offset + 4 > optional_offset + optional_size
            or section_table_end > len(payload)
            or struct.unpack_from("<I", payload, directory_count_offset)[0] < 5
        ):
            raise WindowsSigningDeltaError("pe_invalid")
        certificate_offset, certificate_size = struct.unpack_from(
            "<II", payload, security_directory_offset
        )
        return _PeLayout(
            checksum_offset=checksum_offset,
            security_directory_offset=security_directory_offset,
            certificate_offset=certificate_offset,
            certificate_size=certificate_size,
        )
    except WindowsSigningDeltaError:
        raise
    except (IndexError, struct.error) as error:
        raise WindowsSigningDeltaError("pe_invalid") from error


def _normalized_image_sha256(payload: bytes, layout: _PeLayout, end: int) -> str:
    ranges = sorted(
        (
            (layout.checksum_offset, layout.checksum_offset + 4),
            (layout.security_directory_offset, layout.security_directory_offset + 8),
        )
    )
    digest = hashlib.sha256()
    cursor = 0
    for start, stop in ranges:
        if start < cursor or stop > end:
            raise WindowsSigningDeltaError("pe_layout_changed")
        digest.update(payload[cursor:start])
        digest.update(b"\x00" * (stop - start))
        cursor = stop
    digest.update(payload[cursor:end])
    return digest.hexdigest()


def _validate_certificate_table(payload: bytes, start: int, size: int) -> None:
    end = start + size
    cursor = start
    if size <= 0 or size % 8 != 0 or end != len(payload):
        raise WindowsSigningDeltaError("pe_authenticode_invalid")
    while cursor < end:
        if cursor % 8 != 0 or cursor + 8 > end:
            raise WindowsSigningDeltaError("pe_authenticode_invalid")
        length, revision, certificate_type = struct.unpack_from("<IHH", payload, cursor)
        if (
            length <= 8
            or revision != _WIN_CERT_REVISION_2_0
            or certificate_type != _WIN_CERT_TYPE_PKCS_SIGNED_DATA
            or cursor + length > end
        ):
            raise WindowsSigningDeltaError("pe_authenticode_invalid")
        aligned_end = (cursor + length + 7) & ~7
        if aligned_end > end or any(payload[cursor + length : aligned_end]):
            raise WindowsSigningDeltaError("pe_authenticode_invalid")
        cursor = aligned_end
    if cursor != end:
        raise WindowsSigningDeltaError("pe_authenticode_invalid")


def _validate_authenticode_insertion(
    before: bytes,
    after: bytes,
) -> dict[str, object]:
    before_layout = _parse_pe(before)
    after_layout = _parse_pe(after)
    if (
        before_layout.checksum_offset != after_layout.checksum_offset
        or before_layout.security_directory_offset
        != after_layout.security_directory_offset
    ):
        raise WindowsSigningDeltaError("pe_layout_changed")
    if before_layout.certificate_offset or before_layout.certificate_size:
        raise WindowsSigningDeltaError("pe_preexisting_certificate")
    certificate_offset = after_layout.certificate_offset
    certificate_size = after_layout.certificate_size
    expected_certificate_offset = (len(before) + 7) & ~7
    if (
        certificate_offset != expected_certificate_offset
        or certificate_offset + certificate_size != len(after)
        or certificate_size <= 0
    ):
        raise WindowsSigningDeltaError("pe_authenticode_invalid")
    before_normalized = _normalized_image_sha256(before, before_layout, len(before))
    after_normalized = _normalized_image_sha256(after, after_layout, len(before))
    if before_normalized != after_normalized:
        raise WindowsSigningDeltaError("pe_content_changed")
    if any(after[len(before) : certificate_offset]):
        raise WindowsSigningDeltaError("pe_authenticode_invalid")
    _validate_certificate_table(after, certificate_offset, certificate_size)
    return {
        "normalized_image_sha256": before_normalized,
        "certificate_offset": certificate_offset,
        "certificate_size": certificate_size,
        "certificate_table_sha256": hashlib.sha256(
            after[certificate_offset:]
        ).hexdigest(),
    }


def _receipt(body: dict[str, object]) -> dict[str, object]:
    return {**body, "receipt_body_sha256": canonical_sha256(body)}


def validate_windows_signing_delta(
    before_manifest: Path,
    after_manifest: Path,
    catalog_path: Path,
    before_root: Path,
    after_root: Path,
) -> dict[str, object]:
    """Validate one exact Windows unsigned-to-signed inventory transition."""
    before = _load_inventory(before_manifest)
    after = _load_inventory(after_manifest)
    if (
        before["surface"] != after["surface"]
        or before["architecture"] != after["architecture"]
    ):
        raise WindowsSigningDeltaError("scope_mismatch")
    _inventory_root(before_root, before, stability_check=False)
    _inventory_root(after_root, after, stability_check=False)
    catalog_paths, catalog_sha256 = _load_catalog(catalog_path)

    before_native = {
        str(entry["path"]): entry
        for entry in before["native_code"]  # type: ignore[index]
    }
    after_native = {
        str(entry["path"]): entry
        for entry in after["native_code"]  # type: ignore[index]
    }
    planned_native = set(catalog_paths)
    if not planned_native or set(before_native) != planned_native:
        raise WindowsSigningDeltaError("catalog_mismatch")
    if set(after_native) != planned_native:
        raise WindowsSigningDeltaError("native_set_changed")

    before_entries = {
        str(entry["path"]): entry
        for entry in before["candidate_entries"]  # type: ignore[index]
    }
    after_entries = {
        str(entry["path"]): entry
        for entry in after["candidate_entries"]  # type: ignore[index]
    }
    removed = set(before_entries) - set(after_entries)
    added = set(after_entries) - set(before_entries)
    if removed:
        raise WindowsSigningDeltaError("path_removed")
    if added:
        raise WindowsSigningDeltaError("path_added")
    changed_native_count = 0
    pe_proofs: list[dict[str, object]] = []
    for relative in sorted(before_entries):
        before_entry = before_entries[relative]
        after_entry = after_entries[relative]
        if before_entry.get("kind") != after_entry.get("kind"):
            raise WindowsSigningDeltaError("kind_changed")
        if before_entry.get("mode") != after_entry.get("mode"):
            raise WindowsSigningDeltaError("mode_changed")
        if before_entry.get("link_target") != after_entry.get("link_target"):
            raise WindowsSigningDeltaError("link_target_changed")
        if relative not in planned_native:
            if before_entry != after_entry:
                raise WindowsSigningDeltaError("content_changed_outside_catalog")
            continue
        changed = before_entry.get("bytes") != after_entry.get(
            "bytes"
        ) or before_entry.get("sha256") != after_entry.get("sha256")
        if not changed:
            raise WindowsSigningDeltaError("planned_native_unchanged")
        changed_native_count += 1

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
            raise WindowsSigningDeltaError("native_metadata_invalid")
        proof = _validate_authenticode_insertion(
            _read_root_file(before_root, relative),
            _read_root_file(after_root, relative),
        )
        pe_proofs.append({"path": relative, **proof})

    for field in (
        "schema",
        "platform",
        "surface",
        "architecture",
        "candidate_file_count",
        "candidate_entry_count",
        "native_code_count",
    ):
        if before[field] != after[field]:
            raise WindowsSigningDeltaError("root_metadata_mismatch")

    if before["candidate_sha256"] == after["candidate_sha256"]:
        raise WindowsSigningDeltaError("candidate_unchanged")

    _inventory_root(before_root, before, stability_check=True)
    _inventory_root(after_root, after, stability_check=True)
    try:
        if _load_inventory(before_manifest) != before:
            raise WindowsSigningDeltaError("input_unstable")
        if _load_inventory(after_manifest) != after:
            raise WindowsSigningDeltaError("input_unstable")
        repeated_catalog_paths, repeated_catalog_sha256 = _load_catalog(catalog_path)
    except WindowsSigningDeltaError as error:
        if error.code == "input_unstable":
            raise
        raise WindowsSigningDeltaError("input_unstable") from error
    if (
        repeated_catalog_paths != catalog_paths
        or repeated_catalog_sha256 != catalog_sha256
    ):
        raise WindowsSigningDeltaError("input_unstable")

    body = {
        "schema": SCHEMA,
        "ok": True,
        "platform": "windows",
        "surface": before["surface"],
        "architecture": before["architecture"],
        "before_candidate_sha256": before["candidate_sha256"],
        "after_candidate_sha256": after["candidate_sha256"],
        "before_inventory_sha256": before["inventory_sha256"],
        "after_inventory_sha256": after["inventory_sha256"],
        "catalog_sha256": catalog_sha256,
        "candidate_entry_count": before["candidate_entry_count"],
        "planned_native_count": len(planned_native),
        "changed_native_count": changed_native_count,
        "normalized_images_sha256": canonical_sha256(
            [
                {
                    "path": proof["path"],
                    "sha256": proof["normalized_image_sha256"],
                }
                for proof in pe_proofs
            ]
        ),
        "certificate_tables_sha256": canonical_sha256(
            [
                {
                    "path": proof["path"],
                    "offset": proof["certificate_offset"],
                    "bytes": proof["certificate_size"],
                    "sha256": proof["certificate_table_sha256"],
                }
                for proof in pe_proofs
            ]
        ),
    }
    return _receipt(body)


def _is_junction(path: Path) -> bool:
    predicate = getattr(path, "is_junction", None)
    try:
        return bool(predicate is not None and predicate())
    except OSError as error:
        raise WindowsSigningDeltaError("receipt_path_invalid") from error


def _publish_receipt(
    path: Path,
    receipt: dict[str, object],
    *,
    protected_paths: tuple[Path, ...] = (),
) -> None:
    payload = (
        json.dumps(receipt, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")
    if not payload or len(payload) > MAX_RECEIPT_BYTES:
        raise WindowsSigningDeltaError("receipt_too_large")
    descriptor = -1
    temporary: Path | None = None
    try:
        requested = Path(path)
        name = requested.name
        parent = requested.parent.resolve(strict=True)
        if (
            not parent.is_dir()
            or not name
            or name in {".", ".."}
            or name != name.rstrip(" .")
            or ":" in name
            or any(ord(character) < 32 or ord(character) == 127 for character in name)
            or requested.is_symlink()
            or _is_junction(requested)
        ):
            raise WindowsSigningDeltaError("receipt_path_invalid")
        resolved = parent / name
        if resolved.exists() and not stat.S_ISREG(resolved.lstat().st_mode):
            raise WindowsSigningDeltaError("receipt_path_invalid")
        for protected in protected_paths:
            protected_resolved = protected.resolve(strict=False)
            if resolved == protected_resolved:
                raise WindowsSigningDeltaError("receipt_path_invalid")
            if protected_resolved.is_dir():
                try:
                    resolved.relative_to(protected_resolved)
                except ValueError:
                    pass
                else:
                    raise WindowsSigningDeltaError("receipt_path_invalid")
            if (
                resolved.exists()
                and protected.exists()
                and os.path.samefile(resolved, protected)
            ):
                raise WindowsSigningDeltaError("receipt_path_invalid")

        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{name}.", suffix=".tmp", dir=parent
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if temporary.read_bytes() != payload:
            raise WindowsSigningDeltaError("receipt_write_failed")
        os.replace(temporary, resolved)
        temporary = None
        metadata = resolved.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size != len(payload)
            or resolved.read_bytes() != payload
        ):
            raise WindowsSigningDeltaError("receipt_write_failed")
    except WindowsSigningDeltaError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise WindowsSigningDeltaError("receipt_write_failed") from error
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
        description="Validate an exact Windows unsigned-to-signed inventory delta."
    )
    parser.add_argument(
        "--before", "--unsigned", dest="before", required=True, type=Path
    )
    parser.add_argument("--after", "--signed", dest="after", required=True, type=Path)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--before-root", required=True, type=Path)
    parser.add_argument("--after-root", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    protected_paths = (
        args.before,
        args.after,
        args.catalog,
        args.before_root,
        args.after_root,
    )
    try:
        receipt = validate_windows_signing_delta(
            args.before,
            args.after,
            args.catalog,
            args.before_root,
            args.after_root,
        )
        _publish_receipt(
            args.receipt,
            receipt,
            protected_paths=protected_paths,
        )
    except WindowsSigningDeltaError as error:
        failure_body: dict[str, object] = {
            "schema": ERROR_SCHEMA,
            "ok": False,
            "code": error.code,
        }
        failure = _receipt(failure_body)
        try:
            _publish_receipt(
                args.receipt,
                failure,
                protected_paths=protected_paths,
            )
        except WindowsSigningDeltaError as receipt_error:
            failure_body["receipt_error_code"] = receipt_error.code
            failure = _receipt(failure_body)
        print(json.dumps(failure, separators=(",", ":"), sort_keys=True))
        return 1
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "changed_native_count": receipt["changed_native_count"],
                "receipt_body_sha256": receipt["receipt_body_sha256"],
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
