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

    def test_matching_release_tag_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)

            self.assertEqual(
                check_release_versions(root, tag="v1.2.3"),
                ("1.2.3", "17"),
            )

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
    def _write_fixture(root: Path, locked_version: str = "1.2.3") -> None:
        files = {
            "collector/pubspec.yaml": "version: 1.2.3\n",
            "collector/bin/collect.dart": "const _version = '1.2.3';\n",
            "collector/lib/mcp.dart": ("const quotabotMcpVersion = '1.2.3';\n"),
            "app/pubspec.yaml": "version: 1.2.3+17\n",
            "app/pubspec.lock": (
                "packages:\n"
                "  quotabot_collector:\n"
                "    dependency: direct\n"
                f'    version: "{locked_version}"\n'
                "  test:\n"
                "    dependency: transitive\n"
                '    version: "1.0.0"\n'
            ),
            "ROADMAP.md": (
                "The current line, **1.2.3**, contains the release candidate.\n"
            ),
            "CHANGELOG.md": "## Unreleased\n\n## 1.2.3 - 2026-07-09\n",
        }
        for relative_path, content in files.items():
            path = root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
