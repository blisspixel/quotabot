#!/usr/bin/env python3
"""Verify a quotabot desktop release archive and its checksum sidecar."""

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
    r"^quotabot-(windows|darwin|linux)-(x64|arm64)-desktop"
    r"\.(zip|tar\.gz)$"
)
MAX_ARCHIVE_ENTRIES = 20_000
MAX_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024


class DesktopArchiveError(ValueError):
    """Raised when a release archive violates the public asset contract."""


@dataclass(frozen=True)
class DesktopArchive:
    path: Path
    operating_system: str
    architecture: str
    sha256: str
    entries: tuple[str, ...]


def _normalized_entry(name: str) -> str:
    if not name or "\x00" in name:
        raise DesktopArchiveError("archive contains an empty or invalid path")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise DesktopArchiveError(
            f"archive path contains a control character: {name!r}"
        )
    portable = name.replace("\\", "/")
    if portable.startswith("/") or re.match(r"^[A-Za-z]:", portable):
        raise DesktopArchiveError(f"archive path is absolute: {name}")
    raw_parts = portable.split("/")
    if ".." in raw_parts:
        raise DesktopArchiveError(f"archive path escapes its root: {name}")
    normalized = str(PurePosixPath(portable))
    while normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized in {"", "."}:
        return "."
    return normalized.rstrip("/")


def _validate_link(entry_name: str, target: str) -> None:
    portable = target.replace("\\", "/")
    if not portable or portable.startswith("/") or re.match(r"^[A-Za-z]:", portable):
        raise DesktopArchiveError(f"archive link target is unsafe: {entry_name}")
    stack = list(PurePosixPath(_normalized_entry(entry_name)).parent.parts)
    for part in portable.split("/"):
        if part in {"", "."}:
            continue
        if part == "..":
            if not stack:
                raise DesktopArchiveError(
                    f"archive link target escapes its root: {entry_name}"
                )
            stack.pop()
        else:
            stack.append(part)


def _archive_entries(
    path: Path,
    extension: str,
) -> tuple[tuple[str, ...], frozenset[str], frozenset[str]]:
    nonempty_regular: set[str] = set()
    executable_regular: set[str] = set()
    if extension == "zip":
        try:
            with zipfile.ZipFile(path) as archive:
                infos = archive.infolist()
                if len(infos) > MAX_ARCHIVE_ENTRIES:
                    raise DesktopArchiveError(
                        "desktop archive contains too many entries"
                    )
                if sum(entry.file_size for entry in infos) > MAX_UNCOMPRESSED_BYTES:
                    raise DesktopArchiveError(
                        "desktop archive expands beyond the size limit"
                    )
                for entry in infos:
                    mode = entry.external_attr >> 16
                    if stat.S_ISLNK(mode):
                        if entry.file_size > 4096:
                            raise DesktopArchiveError(
                                f"archive link target is oversized: {entry.filename}"
                            )
                        try:
                            target = archive.read(entry).decode("utf-8")
                        except UnicodeDecodeError as error:
                            raise DesktopArchiveError(
                                f"archive link target is not UTF-8: {entry.filename}"
                            ) from error
                        _validate_link(entry.filename, target)
                        continue
                    file_type = stat.S_IFMT(mode)
                    if file_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
                        raise DesktopArchiveError(
                            f"ZIP archive contains a special file: {entry.filename}"
                        )
                    if (
                        file_type in {0, stat.S_IFREG}
                        and not entry.is_dir()
                        and entry.file_size > 0
                    ):
                        normalized = _normalized_entry(entry.filename)
                        nonempty_regular.add(normalized)
                        if mode & 0o111:
                            executable_regular.add(normalized)
                names = [entry.filename for entry in infos]
        except (OSError, zipfile.BadZipFile) as error:
            raise DesktopArchiveError(f"invalid ZIP archive: {error}") from error
    else:
        try:
            with tarfile.open(path, mode="r:gz") as archive:
                members = archive.getmembers()
                if len(members) > MAX_ARCHIVE_ENTRIES:
                    raise DesktopArchiveError(
                        "desktop archive contains too many entries"
                    )
                if sum(entry.size for entry in members) > MAX_UNCOMPRESSED_BYTES:
                    raise DesktopArchiveError(
                        "desktop archive expands beyond the size limit"
                    )
                for entry in members:
                    if not (
                        entry.isfile()
                        or entry.isdir()
                        or entry.issym()
                        or entry.islnk()
                    ):
                        raise DesktopArchiveError(
                            f"archive contains a special file: {entry.name}"
                        )
                    if entry.islnk():
                        raise DesktopArchiveError(
                            f"tar archive contains a hard link: {entry.name}"
                        )
                    if entry.issym():
                        _validate_link(entry.name, entry.linkname)
                    elif entry.isfile() and entry.size > 0:
                        normalized = _normalized_entry(entry.name)
                        nonempty_regular.add(normalized)
                        if entry.mode & 0o111:
                            executable_regular.add(normalized)
                names = [entry.name for entry in members]
        except (OSError, tarfile.TarError) as error:
            raise DesktopArchiveError(f"invalid tar archive: {error}") from error

    normalized = tuple(
        entry for entry in (_normalized_entry(name) for name in names) if entry != "."
    )
    if not normalized:
        raise DesktopArchiveError("desktop archive is empty")
    if len(normalized) != len(set(normalized)):
        raise DesktopArchiveError("desktop archive contains duplicate paths")
    return normalized, frozenset(nonempty_regular), frozenset(executable_regular)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_sidecar(path: Path, actual_hash: str) -> None:
    sidecar = Path(f"{path}.sha256")
    if not sidecar.is_file():
        raise DesktopArchiveError(f"missing checksum sidecar: {sidecar.name}")
    fields = sidecar.read_text(encoding="utf-8").strip().split()
    if len(fields) != 2:
        raise DesktopArchiveError("checksum sidecar must contain hash and filename")
    expected_hash, expected_name = fields
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise DesktopArchiveError("checksum sidecar hash is not lowercase SHA-256")
    if expected_name != path.name:
        raise DesktopArchiveError("checksum sidecar names a different archive")
    if expected_hash != actual_hash:
        raise DesktopArchiveError("desktop archive checksum mismatch")


def _require_shape(
    operating_system: str,
    entries: tuple[str, ...],
    nonempty_regular: frozenset[str],
    executable_regular: frozenset[str],
) -> None:
    if operating_system in {"windows", "darwin"} and len(
        {entry.casefold() for entry in entries}
    ) != len(entries):
        raise DesktopArchiveError("desktop archive has case-colliding paths")
    if operating_system == "windows":
        required = {"quotabot.exe"}
        prefixes = ("data/flutter_assets/",)
    elif operating_system == "darwin":
        required = {
            "quotabot.app/Contents/Info.plist",
            "quotabot.app/Contents/MacOS/quotabot",
        }
        prefixes = ("quotabot.app/Contents/Frameworks/",)
    else:
        required = {"quotabot"}
        prefixes = ("data/flutter_assets/", "lib/")

    missing = sorted(required.difference(nonempty_regular))
    if missing:
        raise DesktopArchiveError(
            "desktop archive is missing required nonempty regular files: "
            + ", ".join(missing)
        )
    if operating_system == "linux" and "quotabot" not in executable_regular:
        raise DesktopArchiveError(
            "desktop archive executable is not a nonempty executable regular file"
        )
    for prefix in prefixes:
        if not any(entry.startswith(prefix) for entry in nonempty_regular):
            raise DesktopArchiveError(
                f"desktop archive is missing a nonempty regular file under: {prefix}"
            )


def verify_desktop_archive(path: Path) -> DesktopArchive:
    resolved = path.resolve()
    if not resolved.is_file():
        raise DesktopArchiveError(f"desktop archive not found: {path}")
    match = ASSET_PATTERN.fullmatch(resolved.name)
    if match is None:
        raise DesktopArchiveError(f"unexpected desktop asset name: {resolved.name}")
    operating_system, architecture, extension = match.groups()
    expected_extension = "tar.gz" if operating_system == "linux" else "zip"
    if extension != expected_extension:
        raise DesktopArchiveError(
            f"{operating_system} desktop asset must use .{expected_extension}"
        )

    actual_hash = _sha256(resolved)
    _verify_sidecar(resolved, actual_hash)
    entries, nonempty_regular, executable_regular = _archive_entries(
        resolved,
        extension,
    )
    _require_shape(
        operating_system,
        entries,
        nonempty_regular,
        executable_regular,
    )
    return DesktopArchive(
        path=resolved,
        operating_system=operating_system,
        architecture=architecture,
        sha256=actual_hash,
        entries=entries,
    )


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("usage: verify_desktop_archive.py ARCHIVE", file=sys.stderr)
        return 2
    try:
        result = verify_desktop_archive(Path(args[0]))
    except DesktopArchiveError as error:
        print(f"desktop archive verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"verified {result.path.name}: {result.operating_system}/"
        f"{result.architecture}, {len(result.entries)} entries, "
        f"sha256 {result.sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
