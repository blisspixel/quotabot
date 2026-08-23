import tempfile
import unittest
from pathlib import Path

from tools.check_release_version import VersionCheckError, check_release_versions


class ReleaseVersionCheckTests(unittest.TestCase):
    def test_matching_release_surfaces_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)

            self.assertEqual(check_release_versions(root), ("1.2.3", "17"))

    def test_stale_lockfile_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root, locked_version="1.2.2")

            with self.assertRaisesRegex(
                VersionCheckError,
                r"expected 1\.2\.3; mismatched Flutter collector lock=1\.2\.2",
            ):
                check_release_versions(root)

    def test_stale_desktop_update_version_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)
            (root / "app/lib/update_check.dart").write_text(
                "const String quotabotAppVersion = '1.2.2';\n"
                "const String quotabotAppBuild = '1.2.3+17';\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                VersionCheckError,
                r"expected 1\.2\.3; mismatched Flutter update check=1\.2\.2",
            ):
                check_release_versions(root)

    def test_stale_displayed_build_number_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)
            (root / "app/lib/update_check.dart").write_text(
                "const String quotabotAppVersion = '1.2.3';\n"
                "const String quotabotAppBuild = '1.2.3+16';\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                VersionCheckError,
                r"displayed build number 16 does not match .* build number 17",
            ):
                check_release_versions(root)

    def test_stale_readme_release_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)
            (root / "README.md").write_text(
                "> **Current stable:** 1.2.2. Release notes.\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                VersionCheckError,
                r"expected 1\.2\.3; mismatched README current stable=1\.2\.2",
            ):
                check_release_versions(root)

    def test_stale_security_release_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)
            (root / "SECURITY.md").write_text(
                "  The current audited release is "
                "[v1.2.2](https://github.com/blisspixel/quotabot/releases/tag/v1.2.2).\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                VersionCheckError,
                r"expected 1\.2\.3; mismatched SECURITY current audited release=1\.2\.2",
            ):
                check_release_versions(root)

    def test_matching_release_tag_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)

            self.assertEqual(
                check_release_versions(root, tag="v1.2.3"),
                ("1.2.3", "17"),
            )

    def test_prerelease_source_keeps_consistent_stable_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.3.0-rc.1",
                stable_version="1.2.3",
                locked_version="1.3.0-rc.1",
            )

            self.assertEqual(
                check_release_versions(root, tag="v1.3.0-rc.1"),
                ("1.3.0-rc.1", "17"),
            )

    def test_prerelease_rejects_disagreeing_stable_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.3.0-rc.1",
                stable_version="1.2.3",
                locked_version="1.3.0-rc.1",
            )
            (root / "SECURITY.md").write_text(
                "  The current audited release is "
                "[v1.2.2](https://github.com/blisspixel/quotabot/releases/tag/v1.2.2).\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                VersionCheckError,
                r"expected stable 1\.2\.3; mismatched "
                r"SECURITY current audited release=1\.2\.2",
            ):
                check_release_versions(root)

    def test_mismatched_release_tag_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)

            with self.assertRaisesRegex(
                VersionCheckError,
                r"tag 'v1\.2\.4' does not match source version v1\.2\.3",
            ):
                check_release_versions(root, tag="v1.2.4")

    @staticmethod
    def _write_fixture(
        root: Path,
        locked_version: str = "1.2.3",
        *,
        source_version: str = "1.2.3",
        stable_version: str = "1.2.3",
    ) -> None:
        files = {
            "collector/pubspec.yaml": f"version: {source_version}\n",
            "collector/bin/collect.dart": (f"const _version = '{source_version}';\n"),
            "collector/lib/mcp.dart": (
                f"const quotabotMcpVersion = '{source_version}';\n"
            ),
            "app/pubspec.yaml": f"version: {source_version}+17\n",
            "app/lib/update_check.dart": (
                f"const String quotabotAppVersion = '{source_version}';\n"
                f"const String quotabotAppBuild = '{source_version}+17';\n"
            ),
            "app/pubspec.lock": (
                "packages:\n"
                "  quotabot_collector:\n"
                "    dependency: direct\n"
                f'    version: "{locked_version}"\n'
                "  test:\n"
                "    dependency: transitive\n"
                '    version: "1.0.0"\n'
            ),
            "README.md": (f"> **Current stable:** {stable_version}. Release notes.\n"),
            "SECURITY.md": (
                "  The current audited release is "
                f"[v{stable_version}](https://github.com/blisspixel/quotabot/"
                f"releases/tag/v{stable_version}).\n"
            ),
            "AGENTS.md": (
                "The current verified stable release is "
                f"{stable_version}. Next steps.\n"
            ),
            "docs/README.md": (
                "The current verified stable release is "
                f"{stable_version}. Next steps.\n"
            ),
            "docs/SETUP.md": (
                "The current stable release is\n"
                f"[v{stable_version}](https://github.com/blisspixel/quotabot/"
                f"releases/tag/v{stable_version}).\n"
            ),
            "ROADMAP.md": (
                f"The current line, **{stable_version}**, "
                "contains the release candidate.\n"
            ),
            "CHANGELOG.md": (f"## Unreleased\n\n## {source_version} - 2026-07-09\n"),
        }
        for relative_path, content in files.items():
            path = root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
