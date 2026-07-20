#!/usr/bin/env python3
"""Verify a quotabot CLI release archive and its checksum sidecar."""

from __future__ import annotations

import hashlib
import re
import stat
import sys
import tarfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


ASSET_PATTERN = re.compile(
    r"^quotabot-(windows|darwin|linux)-(x64|arm64)\.(zip|tar\.gz)$"
)
MAX_ARCHIVE_ENTRIES = 10_000
MAX_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024


class CliArchiveError(ValueError):
    """Raised when a CLI release archive violates the public asset contract."""


@dataclass(frozen=True)
class CliArchive:
    path: Path
    operating_system: str
    architecture: str
    sha256: str
    entries: tuple[str, ...]


def _normalized_entry(name: str) -> str:
    if not name or "\x00" in name:
        raise CliArchiveError("archive contains an empty or invalid path")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise CliArchiveError(f"archive path contains a control character: {name!r}")
    portable = name.replace("\\", "/")
    if portable.startswith("/") or re.match(r"^[A-Za-z]:", portable):
        raise CliArchiveError(f"archive path is absolute: {name}")
    if ".." in portable.split("/"):
        raise CliArchiveError(f"archive path escapes its root: {name}")
    normalized = str(PurePosixPath(portable))
    while normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized in {"", "."}:
        return "."
    return normalized.rstrip("/")


def _validate_link(entry_name: str, target: str) -> None:
    portable = target.replace("\\", "/")
    if not portable or portable.startswith("/") or re.match(r"^[A-Za-z]:", portable):
        raise CliArchiveError(f"archive link target is unsafe: {entry_name}")
    stack = list(PurePosixPath(_normalized_entry(entry_name)).parent.parts)
    for part in portable.split("/"):
        if part in {"", "."}:
            continue
        if part == "..":
            if not stack:
                raise CliArchiveError(
                    f"archive link target escapes its root: {entry_name}"
                )
            stack.pop()
        else:
            stack.append(part)


def _zip_entries(path: Path) -> tuple[tuple[str, ...], bool, bool]:
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if len(infos) > MAX_ARCHIVE_ENTRIES:
                raise CliArchiveError("CLI archive contains too many entries")
            if sum(entry.file_size for entry in infos) > MAX_UNCOMPRESSED_BYTES:
                raise CliArchiveError("CLI archive expands beyond the size limit")
            for entry in infos:
                mode = entry.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise CliArchiveError(
                        f"ZIP archive contains a symbolic link: {entry.filename}"
                    )
                file_type = stat.S_IFMT(mode)
                if file_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
                    raise CliArchiveError(
                        f"ZIP archive contains a special file: {entry.filename}"
                    )
            names = tuple(entry.filename for entry in infos)
            executable = any(
                _normalized_entry(entry.filename) == "bin/quotabot.exe"
                and not entry.is_dir()
                and entry.file_size > 0
                for entry in infos
            )
            library_file = any(
                _normalized_entry(entry.filename).startswith("lib/")
                and not entry.is_dir()
                and entry.file_size > 0
                for entry in infos
            )
    except (OSError, zipfile.BadZipFile) as error:
        raise CliArchiveError(f"invalid ZIP archive: {error}") from error
    return names, executable, library_file


def _tar_entries(path: Path) -> tuple[tuple[str, ...], bool, bool]:
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            members = archive.getmembers()
            if len(members) > MAX_ARCHIVE_ENTRIES:
                raise CliArchiveError("CLI archive contains too many entries")
            if sum(entry.size for entry in members) > MAX_UNCOMPRESSED_BYTES:
                raise CliArchiveError("CLI archive expands beyond the size limit")
            for entry in members:
                if not (
                    entry.isfile() or entry.isdir() or entry.issym() or entry.islnk()
                ):
                    raise CliArchiveError(
                        f"archive contains a special file: {entry.name}"
                    )
                if entry.islnk():
                    raise CliArchiveError(
                        f"tar archive contains a hard link: {entry.name}"
                    )
                if entry.issym():
                    _validate_link(entry.name, entry.linkname)
            names = tuple(entry.name for entry in members)
            executable = any(
                _normalized_entry(entry.name) == "bin/quotabot"
                and entry.isfile()
                and entry.size > 0
                and entry.mode & 0o111 != 0
                for entry in members
            )
            library_file = any(
                _normalized_entry(entry.name).startswith("lib/")
                and entry.isfile()
                and entry.size > 0
                for entry in members
            )
    except (OSError, tarfile.TarError) as error:
        raise CliArchiveError(f"invalid tar archive: {error}") from error
    return names, executable, library_file


def _archive_entries(path: Path, extension: str) -> tuple[str, ...]:
    names, executable, library_file = (
        _zip_entries(path) if extension == "zip" else _tar_entries(path)
    )
    entries = tuple(
        entry for entry in (_normalized_entry(name) for name in names) if entry != "."
    )
    if not entries:
        raise CliArchiveError("CLI archive is empty")
    if len(entries) != len(set(entries)):
        raise CliArchiveError("CLI archive contains duplicate paths")
    if not executable:
        raise CliArchiveError("CLI archive is missing a nonempty executable")
    if not library_file:
        raise CliArchiveError("CLI archive is missing a nonempty regular library file")
    return entries


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_sidecar(path: Path, actual_hash: str) -> None:
    sidecar = Path(f"{path}.sha256")
    if not sidecar.is_file():
        raise CliArchiveError(f"missing checksum sidecar: {sidecar.name}")
    fields = sidecar.read_text(encoding="utf-8").strip().split()
    if len(fields) != 2:
        raise CliArchiveError("checksum sidecar must contain hash and filename")
    expected_hash, expected_name = fields
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise CliArchiveError("checksum sidecar hash is not lowercase SHA-256")
    if expected_name != path.name:
        raise CliArchiveError("checksum sidecar names a different archive")
    if expected_hash != actual_hash:
        raise CliArchiveError("CLI archive checksum mismatch")


def _require_shape(operating_system: str, entries: tuple[str, ...]) -> None:
    expected_executable = (
        "bin/quotabot.exe" if operating_system == "windows" else "bin/quotabot"
    )
    if expected_executable not in entries:
        raise CliArchiveError(
            f"CLI archive is missing required entry: {expected_executable}"
        )
    if operating_system in {"windows", "darwin"} and len(
        {entry.casefold() for entry in entries}
    ) != len(entries):
        raise CliArchiveError("CLI archive has case-colliding paths")
    unexpected = sorted(
        entry
        for entry in entries
        if entry not in {"bin", "lib"}
        and not entry.startswith("bin/")
        and not entry.startswith("lib/")
    )
    if unexpected:
        raise CliArchiveError(
            "CLI archive contains an unexpected top-level path: " + unexpected[0]
        )


def verify_cli_archive(path: Path) -> CliArchive:
    resolved = path.resolve()
    if not resolved.is_file():
        raise CliArchiveError(f"CLI archive not found: {path}")
    match = ASSET_PATTERN.fullmatch(resolved.name)
    if match is None:
        raise CliArchiveError(f"unexpected CLI asset name: {resolved.name}")
    operating_system, architecture, extension = match.groups()
    expected_extension = "zip" if operating_system == "windows" else "tar.gz"
    if extension != expected_extension:
        raise CliArchiveError(
            f"{operating_system} CLI asset must use .{expected_extension}"
        )

    actual_hash = _sha256(resolved)
    _verify_sidecar(resolved, actual_hash)
    entries = _archive_entries(resolved, extension)
    _require_shape(operating_system, entries)
    return CliArchive(
        path=resolved,
        operating_system=operating_system,
        architecture=architecture,
        sha256=actual_hash,
        entries=entries,
    )


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("usage: verify_cli_archive.py ARCHIVE", file=sys.stderr)
        return 2
    try:
        result = verify_cli_archive(Path(args[0]))
    except CliArchiveError as error:
        print(f"CLI archive verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"verified {result.path.name}: {result.operating_system}/"
        f"{result.architecture}, {len(result.entries)} entries, "
        f"sha256 {result.sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
