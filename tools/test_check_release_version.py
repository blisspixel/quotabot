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

    def test_stable_source_rejects_lingering_candidate_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)
            with (root / "README.md").open("a", encoding="utf-8") as readme:
                readme.write("> **Current release candidate:** 1.2.3.\n")

            with self.assertRaisesRegex(
                VersionCheckError,
                r"README current candidate: stable source must not retain",
            ):
                check_release_versions(root)

    def test_stale_docs_candidate_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.3.0-rc.2",
                stable_version="1.2.3",
                locked_version="1.3.0-rc.2",
            )
            (root / "docs/README.md").write_text(
                "The current verified stable release is 1.2.3. "
                "The current release candidate is\n"
                "1.3.0-rc.1. The next work in the focused 0.10.x train.\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                VersionCheckError,
                r"expected 1\.3\.0-rc\.2; mismatched "
                r"docs index current candidate=1\.3\.0-rc\.1",
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

    def test_pending_publication_preserves_published_stable_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.2.4",
                stable_version="1.2.3",
                locked_version="1.2.4",
                pending_version="1.2.4",
            )

            self.assertEqual(
                check_release_versions(root, tag="v1.2.4"), ("1.2.4", "17")
            )

    def test_newer_source_without_pending_marker_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.2.4",
                stable_version="1.2.3",
                locked_version="1.2.4",
            )

            with self.assertRaisesRegex(
                VersionCheckError, r"expected 1\.2\.4; mismatched"
            ):
                check_release_versions(root)

    def test_pending_publication_requires_exact_source_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root, pending_version="1.2.4")

            with self.assertRaisesRegex(
                VersionCheckError,
                r"pending publication 1\.2\.4 does not match source version 1\.2\.3",
            ):
                check_release_versions(root)

    def test_pending_publication_rejects_malformed_or_duplicate_markers(self) -> None:
        markers = (
            "> **Pending publication:** 1.2.4\n",
            "> **Pending publication:** v1.2.4.\n",
            "> **Pending publication:** 1.2.4. Release notes.\n",
            " **Pending publication:** 1.2.4.\n",
            "> **pending publication:** 1.2.4.\n",
            "> **Pending publication:** 1.2.4.\n" * 2,
        )
        for marker in markers:
            with (
                self.subTest(marker=marker),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                self._write_fixture(
                    root,
                    source_version="1.2.4",
                    stable_version="1.2.3",
                    locked_version="1.2.4",
                )
                with (root / "README.md").open("a", encoding="utf-8") as readme:
                    readme.write(marker)

                with self.assertRaisesRegex(
                    VersionCheckError, r"pending publication marker"
                ):
                    check_release_versions(root)

    def test_pending_publication_rejects_prerelease_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.3.0-rc.1",
                stable_version="1.2.3",
                locked_version="1.3.0-rc.1",
                pending_version="1.3.0-rc.1",
            )

            with self.assertRaisesRegex(
                VersionCheckError,
                r"prerelease source must not declare pending publication",
            ):
                check_release_versions(root)

    def test_pending_publication_requires_newer_stable_version(self) -> None:
        for source_version in ("1.2.3", "1.2.2", "1.1.9", "0.99.99", "01.2.4"):
            with (
                self.subTest(source_version=source_version),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                self._write_fixture(
                    root,
                    source_version=source_version,
                    stable_version="1.2.3",
                    locked_version=source_version,
                    pending_version=source_version,
                )

                with self.assertRaisesRegex(
                    VersionCheckError,
                    r"pending publication (must be newer|requires a stable version)",
                ):
                    check_release_versions(root)

    def test_pending_publication_compares_versions_numerically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.2.10",
                stable_version="1.2.9",
                locked_version="1.2.10",
                pending_version="1.2.10",
            )

            self.assertEqual(check_release_versions(root), ("1.2.10", "17"))

    def test_pending_publication_rejects_prerelease_stable_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.3.0",
                stable_version="1.2.3-rc.1",
                locked_version="1.3.0",
                pending_version="1.3.0",
            )

            with self.assertRaisesRegex(
                VersionCheckError, r"README current stable must not name a prerelease"
            ):
                check_release_versions(root)

    def test_pending_publication_rejects_each_disagreeing_stable_marker(self) -> None:
        for path in (
            "README.md",
            "SECURITY.md",
            "AGENTS.md",
            "docs/README.md",
            "docs/SETUP.md",
            "ROADMAP.md",
        ):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._write_fixture(
                    root,
                    source_version="1.2.4",
                    stable_version="1.2.3",
                    locked_version="1.2.4",
                    pending_version="1.2.4",
                )
                target = root / path
                target.write_text(
                    target.read_text(encoding="utf-8").replace("1.2.3", "1.2.2"),
                    encoding="utf-8",
                )

                with self.assertRaisesRegex(
                    VersionCheckError, r"expected stable .*; mismatched"
                ):
                    check_release_versions(root)

    def test_pending_publication_does_not_mask_source_or_tag_mismatch(self) -> None:
        for path in (
            "collector/bin/collect.dart",
            "collector/lib/mcp.dart",
            "app/pubspec.lock",
            "CHANGELOG.md",
        ):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._write_fixture(
                    root,
                    source_version="1.2.4",
                    stable_version="1.2.3",
                    locked_version="1.2.4",
                    pending_version="1.2.4",
                )
                target = root / path
                target.write_text(
                    target.read_text(encoding="utf-8").replace("1.2.4", "1.2.3"),
                    encoding="utf-8",
                )

                with self.assertRaisesRegex(
                    VersionCheckError, r"expected 1\.2\.4; mismatched"
                ):
                    check_release_versions(root)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(
                root,
                source_version="1.2.4",
                stable_version="1.2.3",
                locked_version="1.2.4",
                pending_version="1.2.4",
            )
            with self.assertRaisesRegex(
                VersionCheckError,
                r"tag 'v1\.2\.3' does not match source version v1\.2\.4",
            ):
                check_release_versions(root, tag="v1.2.3")

    def test_publication_promotion_removes_pending_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root, pending_version="1.2.3")
            with self.assertRaisesRegex(
                VersionCheckError, r"pending publication must be newer"
            ):
                check_release_versions(root)

            readme = root / "README.md"
            readme.write_text(
                readme.read_text(encoding="utf-8").replace(
                    "> **Pending publication:** 1.2.3.\n", ""
                ),
                encoding="utf-8",
            )
            self.assertEqual(check_release_versions(root), ("1.2.3", "17"))

    @staticmethod
    def _write_fixture(
        root: Path,
        locked_version: str = "1.2.3",
        *,
        source_version: str = "1.2.3",
        stable_version: str = "1.2.3",
        pending_version: str | None = None,
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
            "README.md": (
                f"> **Current stable:** {stable_version}. Release notes.\n"
                + (
                    f"> **Current release candidate:** {source_version}.\n"
                    if "-" in source_version
                    else ""
                )
                + (
                    f"> **Pending publication:** {pending_version}.\n"
                    if pending_version is not None
                    else ""
                )
            ),
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
                f"{stable_version}. "
                + (
                    f"The current release candidate is\n{source_version}. "
                    if "-" in source_version
                    else ""
                )
                + "The next work in the focused 0.10.x train.\n"
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
