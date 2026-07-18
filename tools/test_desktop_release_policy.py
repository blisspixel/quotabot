"""Static policy tests for prebuilt desktop release publication."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DesktopReleasePolicyTests(unittest.TestCase):
    def test_release_serializes_same_tag_without_cancelling(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        header = workflow.split("jobs:", 1)[0]

        self.assertIn("concurrency:", header)
        self.assertIn("group: ${{ github.workflow }}-${{ github.ref }}", header)
        self.assertIn("cancel-in-progress: false", header)

    def test_release_waits_for_every_desktop_asset(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("build-desktop:", workflow)
        self.assertIn("verify-desktop-release:", workflow)
        self.assertIn("needs: [create-release, build-desktop]", workflow)
        self.assertIn("audit-release-assets:", workflow)
        self.assertIn(
            "needs: [create-release, build, verify-desktop-release]", workflow
        )
        self.assertIn("needs: audit-release-assets", workflow)
        self.assertIn("Refusing to replace assets on published release", workflow)
        for asset in (
            "release/quotabot-windows-x64-desktop.zip",
            "release/quotabot-darwin-arm64-desktop.zip",
            "release/quotabot-linux-x64-desktop.tar.gz",
        ):
            self.assertIn(asset, workflow)

        audit_job = workflow.split("  audit-release-assets:\n", 1)[1].split(
            "  publish-release:\n", 1
        )[0]
        self.assertIn("Draft release asset set is incomplete or unexpected", audit_job)
        self.assertEqual(audit_job.count(".sha256"), 8)
        self.assertIn("sha256sum --check", audit_job)
        self.assertEqual(audit_job.count("python tools/verify_desktop_archive.py"), 3)
        self.assertIn("gh attestation verify", audit_job)

    def test_desktop_archive_is_verified_before_attestation_and_upload(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        desktop_job = workflow.split("  build-desktop:\n", 1)[1].split(
            "  publish-release:\n", 1
        )[0]

        verify_at = desktop_job.index("python tools/verify_desktop_archive.py")
        attest_at = desktop_job.index("actions/attest-build-provenance@")
        upload_at = desktop_job.index("gh release upload")
        self.assertLess(verify_at, attest_at)
        self.assertLess(attest_at, upload_at)

    def test_clean_runner_reverifies_and_launches_uploaded_assets(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        verify_job = workflow.split("  verify-desktop-release:\n", 1)[1].split(
            "  publish-release:\n", 1
        )[0]

        download_at = verify_job.index("Accept: application/octet-stream")
        checksum_at = verify_job.index("verify_desktop_archive.py")
        attestation_at = verify_job.index("gh attestation verify")
        readiness_at = verify_job.index("desktop_readiness_smoke.py")
        self.assertLess(download_at, checksum_at)
        self.assertLess(checksum_at, attestation_at)
        self.assertLess(attestation_at, readiness_at)
        self.assertIn('if: runner.os == \'macOS\'', verify_job)
        self.assertIn("plutil -lint", verify_job)
        self.assertIn("contents: write", verify_job)
        self.assertIn("release-sentinel", verify_job)
        self.assertIn("quotabot-desktop-current", verify_job)
        self.assertIn("quotabot-desktop-previous", verify_job)
        self.assertIn("Portable uninstall removed", verify_job)

    def test_each_packager_writes_the_matching_checksum_sidecar(self) -> None:
        windows = (ROOT / "tools" / "package-windows.ps1").read_text(
            encoding="utf-8"
        )
        linux = (ROOT / "tools" / "package-linux.sh").read_text(encoding="utf-8")
        macos = (ROOT / "tools" / "package-macos.sh").read_text(encoding="utf-8")

        self.assertIn("quotabot-windows-x64-desktop.zip", windows)
        self.assertIn("$archive.sha256", windows)
        self.assertIn("quotabot-linux-$arch-desktop.tar.gz", linux)
        self.assertIn('> "$out.sha256"', linux)
        self.assertIn("quotabot-darwin-$arch-desktop.zip", macos)
        self.assertIn('> "$out.sha256"', macos)

    def test_normal_ci_builds_and_verifies_native_desktop_archives(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("tools/package-windows.ps1", workflow)
        self.assertIn("tools/package-linux.sh", workflow)
        self.assertIn("tools/package-macos.sh", workflow)
        self.assertEqual(workflow.count("tools/verify_desktop_archive.py"), 3)
        self.assertNotIn("package-windows.ps1 -NoArchive", workflow)
        self.assertNotIn("package-linux.sh --no-archive", workflow)
        self.assertNotIn("package-macos.sh --no-archive", workflow)


if __name__ == "__main__":
    unittest.main()
