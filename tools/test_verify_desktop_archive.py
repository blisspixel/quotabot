"""Contract tests for native desktop release archives."""

from __future__ import annotations

import hashlib
import io
import stat
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

from tools.verify_desktop_archive import (
    DesktopArchiveError,
    verify_desktop_archive,
)


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
    path = root / "quotabot-windows-x64-desktop.zip"
    with zipfile.ZipFile(path, mode="w") as archive:
        archive.writestr("quotabot.exe", b"exe")
        archive.writestr("data/flutter_assets/AssetManifest.bin", b"assets")
        if extra is not None:
            archive.writestr(extra, b"extra")
    _write_sidecar(path)
    return path


class DesktopArchiveTests(unittest.TestCase):
    def test_accepts_windows_bundle_with_matching_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))

            result = verify_desktop_archive(archive)

        self.assertEqual(result.operating_system, "windows")
        self.assertEqual(result.architecture, "x64")
        self.assertIn("quotabot.exe", result.entries)

    def test_accepts_linux_bundle_and_preserves_executable_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "quotabot-linux-arm64-desktop.tar.gz"
            with tarfile.open(archive, mode="w:gz") as bundle:
                for name, payload, mode in (
                    ("./quotabot", b"binary", 0o755),
                    ("./data/flutter_assets/AssetManifest.bin", b"assets", 0o644),
                    ("./lib/libapp.so", b"library", 0o644),
                ):
                    info = tarfile.TarInfo(name)
                    info.size = len(payload)
                    info.mode = mode
                    bundle.addfile(info, io.BytesIO(payload))
            _write_sidecar(archive)

            result = verify_desktop_archive(archive)

        self.assertEqual(result.operating_system, "linux")
        self.assertEqual(result.architecture, "arm64")

    def test_accepts_macos_app_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "quotabot-darwin-arm64-desktop.zip"
            with zipfile.ZipFile(archive, mode="w") as bundle:
                bundle.writestr("quotabot.app/Contents/Info.plist", b"plist")
                bundle.writestr("quotabot.app/Contents/MacOS/quotabot", b"binary")
                bundle.writestr(
                    "quotabot.app/Contents/Frameworks/App.framework/App",
                    b"framework",
                )
            _write_sidecar(archive)

            result = verify_desktop_archive(archive)

        self.assertEqual(result.operating_system, "darwin")

    def test_rejects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))
            _write_sidecar(archive, digest="0" * 64)

            with self.assertRaisesRegex(DesktopArchiveError, "checksum mismatch"):
                verify_desktop_archive(archive)

    def test_rejects_sidecar_for_a_different_asset(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory))
            _write_sidecar(archive, name="another.zip")

            with self.assertRaisesRegex(DesktopArchiveError, "different archive"):
                verify_desktop_archive(archive)

    def test_rejects_archive_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory), extra="../escape.txt")

            with self.assertRaisesRegex(DesktopArchiveError, "escapes its root"):
                verify_desktop_archive(archive)

    def test_rejects_case_collisions_on_windows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = _windows_archive(Path(directory), extra="QUOTABOT.EXE")

            with self.assertRaisesRegex(DesktopArchiveError, "case-colliding"):
                verify_desktop_archive(archive)

    def test_rejects_tar_link_that_escapes_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "quotabot-linux-x64-desktop.tar.gz"
            with tarfile.open(archive, mode="w:gz") as bundle:
                for name in (
                    "quotabot",
                    "data/flutter_assets/AssetManifest.bin",
                    "lib/libapp.so",
                ):
                    payload = b"content"
                    info = tarfile.TarInfo(name)
                    info.size = len(payload)
                    info.mode = 0o755 if name == "quotabot" else 0o644
                    bundle.addfile(info, io.BytesIO(payload))
                link = tarfile.TarInfo("lib/escape")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../outside"
                bundle.addfile(link)
            _write_sidecar(archive)

            with self.assertRaisesRegex(DesktopArchiveError, "link target escapes"):
                verify_desktop_archive(archive)

    def test_rejects_zip_link_that_escapes_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "quotabot-darwin-arm64-desktop.zip"
            with zipfile.ZipFile(archive, mode="w") as bundle:
                bundle.writestr("quotabot.app/Contents/Info.plist", b"plist")
                bundle.writestr("quotabot.app/Contents/MacOS/quotabot", b"binary")
                bundle.writestr(
                    "quotabot.app/Contents/Frameworks/App.framework/App",
                    b"framework",
                )
                link = zipfile.ZipInfo(
                    "quotabot.app/Contents/Frameworks/escape",
                )
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                bundle.writestr(link, "../../../../outside")
            _write_sidecar(archive)

            with self.assertRaisesRegex(DesktopArchiveError, "link target escapes"):
                verify_desktop_archive(archive)

    def test_rejects_wrong_platform_extension(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = _windows_archive(Path(directory))
            archive = source.with_name("quotabot-linux-x64-desktop.zip")
            source.rename(archive)
            Path(f"{source}.sha256").rename(f"{archive}.sha256")
            _write_sidecar(archive)

            with self.assertRaisesRegex(DesktopArchiveError, "must use .tar.gz"):
                verify_desktop_archive(archive)


if __name__ == "__main__":
    unittest.main()
