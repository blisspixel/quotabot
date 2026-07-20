"""Contract tests for native CLI release archives."""

from __future__ import annotations

import hashlib
import io
import stat
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from tools.verify_cli_archive import CliArchiveError, verify_cli_archive


def _write_sidecar(
    path: Path,
    *,
    name: str | None = None,
    digest: str | None = None,
) -> None:
    actual = digest or hashlib.sha256(path.read_bytes()).hexdigest()
    Path(f"{path}.sha256").write_text(
        f"{actual}  {name or path.name}",
        encoding="utf-8",
    )


def _windows_archive(root: Path, *, extra: str | None = None) -> Path:
    path = root / "quotabot-windows-x64.zip"
    with zipfile.ZipFile(path, mode="w") as archive:
        archive.writestr("bin/quotabot.exe", b"executable")
        archive.writestr("lib/sqlite3.dll", b"library")
        if extra is not None:
            archive.writestr(extra, b"extra")
    _write_sidecar(path)
    return path


def _windows_archive_from_entries(
    root: Path,
    entries: list[tuple[str | zipfile.ZipInfo, bytes]],
) -> Path:
    path = root / "quotabot-windows-x64.zip"
    with zipfile.ZipFile(path, mode="w") as archive:
        for name, payload in entries:
            archive.writestr(name, payload)
    _write_sidecar(path)
    return path


def _posix_archive(
    root: Path,
    *,
    operating_system: str = "linux",
    executable_mode: int = 0o755,
    link_target: str | None = None,
) -> Path:
    path = root / f"quotabot-{operating_system}-arm64.tar.gz"
    with tarfile.open(path, mode="w:gz") as archive:
        for name, payload, mode in (
            ("./bin/quotabot", b"executable", executable_mode),
            ("./lib/libsqlite3.so", b"library", 0o644),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = mode
            archive.addfile(info, io.BytesIO(payload))
        if link_target is not None:
            link = tarfile.TarInfo("./lib/escape")
            link.type = tarfile.SYMTYPE
            link.linkname = link_target
            archive.addfile(link)
    _write_sidecar(path)
    return path


def _archive_with_hard_link(root: Path, target: str) -> Path:
    path = root / "quotabot-linux-x64.tar.gz"
    with tarfile.open(path, mode="w:gz") as archive:
        for name, payload, mode in (
            ("./bin/quotabot", b"executable", 0o755),
            ("./lib/libsqlite3.so", b"library", 0o644),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = mode
            archive.addfile(info, io.BytesIO(payload))
        link = tarfile.TarInfo("./lib/alias")
        link.type = tarfile.LNKTYPE
        link.linkname = target
        archive.addfile(link)
    _write_sidecar(path)
    return path


def _archive_with_symlink_only_library(root: Path) -> Path:
    path = root / "quotabot-linux-x64.tar.gz"
    with tarfile.open(path, mode="w:gz") as archive:
        executable = tarfile.TarInfo("./bin/quotabot")
        executable.size = len(b"executable")
        executable.mode = 0o755
        archive.addfile(executable, io.BytesIO(b"executable"))
        link = tarfile.TarInfo("./lib/libsqlite3.so")
        link.type = tarfile.SYMTYPE
        link.linkname = "missing-library.so"
        archive.addfile(link)
    _write_sidecar(path)
    return path


class CliArchiveTests(unittest.TestCase):
    def test_accepts_windows_bundle_with_matching_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))

            result = verify_cli_archive(archive)

        self.assertEqual(result.operating_system, "windows")
        self.assertEqual(result.architecture, "x64")
        self.assertIn("bin/quotabot.exe", result.entries)

    def test_accepts_executable_posix_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _posix_archive(Path(directory), operating_system="darwin")

            result = verify_cli_archive(archive)

        self.assertEqual(result.operating_system, "darwin")
        self.assertEqual(result.architecture, "arm64")
        self.assertIn("bin/quotabot", result.entries)

    def test_rejects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))
            _write_sidecar(archive, digest="0" * 64)

            with self.assertRaisesRegex(CliArchiveError, "checksum mismatch"):
                verify_cli_archive(archive)

    def test_rejects_sidecar_for_a_different_asset(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))
            _write_sidecar(archive, name="another.zip")

            with self.assertRaisesRegex(CliArchiveError, "different archive"):
                verify_cli_archive(archive)

    def test_rejects_archive_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory), extra="../escape.txt")

            with self.assertRaisesRegex(CliArchiveError, "escapes its root"):
                verify_cli_archive(archive)

    def test_rejects_unexpected_top_level_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory), extra="install.cmd")

            with self.assertRaisesRegex(CliArchiveError, "unexpected top-level"):
                verify_cli_archive(archive)

    def test_rejects_nonexecutable_posix_binary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _posix_archive(Path(directory), executable_mode=0o644)

            with self.assertRaisesRegex(CliArchiveError, "nonempty executable"):
                verify_cli_archive(archive)

    def test_rejects_tar_link_that_escapes_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _posix_archive(Path(directory), link_target="../../outside")

            with self.assertRaisesRegex(CliArchiveError, "link target escapes"):
                verify_cli_archive(archive)

    def test_rejects_hard_link_with_archive_root_relative_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _archive_with_hard_link(
                Path(directory),
                target="../bin/quotabot",
            )

            with self.assertRaisesRegex(CliArchiveError, "hard link"):
                verify_cli_archive(archive)

    def test_rejects_symlink_only_library_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _archive_with_symlink_only_library(Path(directory))

            with self.assertRaisesRegex(CliArchiveError, "regular library"):
                verify_cli_archive(archive)

    def test_rejects_case_collisions_on_windows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(
                Path(directory),
                extra="BIN/QUOTABOT.EXE",
            )

            with self.assertRaisesRegex(CliArchiveError, "case-colliding"):
                verify_cli_archive(archive)

    def test_rejects_empty_library_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive_from_entries(
                Path(directory),
                [("bin/quotabot.exe", b"executable"), ("lib/", b"")],
            )

            with self.assertRaisesRegex(CliArchiveError, "regular library"):
                verify_cli_archive(archive)

    def test_rejects_zip_symbolic_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            link = zipfile.ZipInfo("lib/sqlite3.dll")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive = _windows_archive_from_entries(
                Path(directory),
                [("bin/quotabot.exe", b"executable"), (link, b"../outside")],
            )

            with self.assertRaisesRegex(CliArchiveError, "symbolic link"):
                verify_cli_archive(archive)

    def test_rejects_normalized_duplicate_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive_from_entries(
                Path(directory),
                [
                    ("bin/quotabot.exe", b"executable"),
                    ("lib/sqlite3.dll", b"library"),
                    ("lib/./sqlite3.dll", b"duplicate"),
                ],
            )

            with self.assertRaisesRegex(CliArchiveError, "duplicate paths"):
                verify_cli_archive(archive)

    def test_rejects_entry_count_over_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))

            with patch("tools.verify_cli_archive.MAX_ARCHIVE_ENTRIES", 1):
                with self.assertRaisesRegex(CliArchiveError, "too many entries"):
                    verify_cli_archive(archive)

    def test_rejects_expanded_size_over_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))

            with patch("tools.verify_cli_archive.MAX_UNCOMPRESSED_BYTES", 4):
                with self.assertRaisesRegex(CliArchiveError, "size limit"):
                    verify_cli_archive(archive)


if __name__ == "__main__":
    unittest.main()
