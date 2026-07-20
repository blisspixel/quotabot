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
            "needs: [create-release, verify-cli-release, verify-desktop-release]",
            workflow,
        )
        publish_job = workflow.split("  publish-release:\n", 1)[1]
        for gate in (
            "audit-release-assets",
            "quality-gate",
            "codeql-gate",
            "secret-scan-gate",
        ):
            self.assertIn(f"      - {gate}", publish_job)
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

    def test_desktop_release_matrix_has_exact_packager_asset_mappings(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        desktop_job = workflow.split("  build-desktop:\n", 1)[1].split(
            "  verify-desktop-release:\n", 1
        )[0]
        matrix = desktop_job.split("      matrix:\n", 1)[1].split("    runs-on:", 1)[0]

        self.assertEqual(
            "        include:\n"
            "          - os: windows-latest\n"
            "            script: pwsh tools/package-windows.ps1\n"
            "            archive: release/quotabot-windows-x64-desktop.zip\n"
            "          - os: macos-latest\n"
            "            script: bash tools/package-macos.sh\n"
            "            archive: release/quotabot-darwin-arm64-desktop.zip\n"
            "          - os: ubuntu-latest\n"
            "            script: bash tools/package-linux.sh\n"
            "            archive: release/quotabot-linux-x64-desktop.tar.gz\n",
            matrix,
        )

    def test_release_executes_every_uploaded_cli_before_publication(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        build_job = workflow.split("  build:\n", 1)[1].split(
            "  verify-cli-release:\n", 1
        )[0]
        verify_job = workflow.split("  verify-cli-release:\n", 1)[1].split(
            "  build-desktop:\n", 1
        )[0]
        audit_job = workflow.split("  audit-release-assets:\n", 1)[1].split(
            "  publish-release:\n", 1
        )[0]

        for asset in (
            "quotabot-windows-x64.zip",
            "quotabot-darwin-arm64.tar.gz",
            "quotabot-linux-x64.tar.gz",
            "quotabot-linux-arm64.tar.gz",
        ):
            self.assertIn(asset, build_job)
            self.assertIn(asset, verify_job)
            self.assertIn(asset, audit_job)

        verify_at = build_job.index("python tools/verify_cli_archive.py")
        attest_at = build_job.index("actions/attest-build-provenance@")
        upload_at = build_job.index("gh release upload")
        self.assertLess(verify_at, attest_at)
        self.assertLess(attest_at, upload_at)
        self.assertNotIn("release/quotabot-*", build_job)

        self.assertIn("needs: [create-release, build]", verify_job)
        self.assertIn("ubuntu-24.04-arm", verify_job)
        self.assertIn("Accept: application/octet-stream", verify_job)
        self.assertIn("gh attestation verify", verify_job)
        self.assertIn("--source-digest", verify_job)
        self.assertIn("--deny-self-hosted-runners", verify_job)
        self.assertIn("QUOTABOT_DEMO: '1'", verify_job)
        self.assertIn("--version", verify_job)
        self.assertEqual(verify_job.count("doctor --json"), 2)
        self.assertEqual(audit_job.count("python tools/verify_cli_archive.py"), 4)

    def test_prerelease_tags_cannot_replace_the_latest_stable_release(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        create_job = workflow.split("  create-release:\n", 1)[1].split("  build:\n", 1)[
            0
        ]
        publish_job = workflow.split("  publish-release:\n", 1)[1]

        self.assertIn("expected_prerelease=false", create_job)
        self.assertIn("expected_prerelease=true", create_job)
        self.assertIn("prerelease_args+=(--prerelease --latest=false)", create_job)
        self.assertIn("--json isDraft,isPrerelease", create_job)
        self.assertIn("Draft prerelease classification does not match", create_job)

        self.assertIn("expected_prerelease=false", publish_job)
        self.assertIn("expected_prerelease=true", publish_job)
        self.assertIn("[.tag_name, .draft, .prerelease] | @tsv", publish_job)
        classification_check = publish_job.index(
            "The draft prerelease classification changed after creation"
        )
        publish = publish_job.index("gh api --method PATCH")
        self.assertLess(classification_check, publish)

    def test_release_runs_exact_tag_quality_and_security_gates(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        codeql = (ROOT / ".github" / "workflows" / "codeql.yml").read_text(
            encoding="utf-8"
        )
        gitleaks = (ROOT / ".github" / "workflows" / "gitleaks.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("uses: ./.github/workflows/ci.yml", release)
        self.assertIn("uses: ./.github/workflows/codeql.yml", release)
        self.assertIn("uses: ./.github/workflows/gitleaks.yml", release)
        self.assertIn("security-events: write", release)
        for reusable in (ci, codeql, gitleaks):
            self.assertIn("  workflow_call:", reusable.split("jobs:", 1)[0])

        create_release = release.split("  create-release:\n", 1)[1].split(
            "  build:\n", 1
        )[0]
        for gate in (
            "preflight",
            "quality-gate",
            "codeql-gate",
            "secret-scan-gate",
        ):
            self.assertIn(f"      - {gate}", create_release)

    def test_every_release_attempt_requires_current_main_tip(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        preflight = release.split("  preflight:\n", 1)[1].split("  quality-gate:\n", 1)[
            0
        ]
        create_job = release.split("  create-release:\n", 1)[1].split("  build:\n", 1)[
            0
        ]

        self.assertIn("fetch-depth: 0", preflight)
        self.assertNotIn("GITHUB_RUN_ATTEMPT", preflight)
        self.assertIn("refs/remotes/origin/main", preflight)
        self.assertIn("tagged_commit=", preflight)
        self.assertIn("main_commit=", preflight)
        self.assertIn('if [ "$tagged_commit" != "$main_commit" ]', preflight)
        self.assertNotIn("git merge-base --is-ancestor", preflight)
        self.assertIn("current protected main tip", preflight)

        main_check_at = create_job.index('main_commit="$(gh api')
        draft_at = create_job.index('if gh release view "$GITHUB_REF_NAME"')
        create_at = create_job.index('gh release create "$GITHUB_REF_NAME"')
        self.assertLess(main_check_at, draft_at)
        self.assertLess(draft_at, create_at)
        self.assertIn('"repos/$GITHUB_REPOSITORY/commits/main"', create_job)
        self.assertIn('if [ "$GITHUB_SHA" != "$main_commit" ]', create_job)
        self.assertIn("Releases must target the current protected main tip", create_job)

    def test_release_repeels_remote_tag_before_create_and_publish(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        create_job = release.split("  create-release:\n", 1)[1].split("  build:\n", 1)[
            0
        ]
        publish_job = release.split("  publish-release:\n", 1)[1]

        for job in (create_job, publish_job):
            self.assertIn(
                '"repos/$GITHUB_REPOSITORY/git/ref/tags/$GITHUB_REF_NAME"', job
            )
            self.assertIn('"repos/$GITHUB_REPOSITORY/git/tags/$object_sha"', job)
            self.assertIn('remote_tag_commit="$(resolve_remote_tag_commit)"', job)
            self.assertIn('if [ "$remote_tag_commit" != "$GITHUB_SHA" ]', job)
            self.assertIn("Release tag indirection is unexpectedly deep", job)

        create_at = create_job.index('gh release create "$GITHUB_REF_NAME"')
        create_peel_at = create_job.rindex(
            'remote_tag_commit="$(resolve_remote_tag_commit)"', 0, create_at
        )
        create_compare_at = create_job.index(
            'if [ "$remote_tag_commit" != "$GITHUB_SHA" ]', create_peel_at
        )
        self.assertLess(create_peel_at, create_compare_at)
        self.assertLess(create_compare_at, create_at)
        self.assertIn("--verify-tag", create_job[create_at:])

        publish_at = publish_job.index("gh api --method PATCH")
        publish_peel_at = publish_job.rindex(
            'remote_tag_commit="$(resolve_remote_tag_commit)"', 0, publish_at
        )
        publish_compare_at = publish_job.index(
            'if [ "$remote_tag_commit" != "$GITHUB_SHA" ]', publish_peel_at
        )
        self.assertLess(publish_peel_at, publish_compare_at)
        self.assertLess(publish_compare_at, publish_at)
        self.assertIn('"repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID"', publish_job)
        self.assertIn("AUDITED_ASSET_MANIFEST_SHA256", publish_job)
        self.assertIn(
            "The draft release asset set changed after final audit", publish_job
        )
        self.assertNotIn('gh release edit "$GITHUB_REF_NAME"', publish_job)

    def test_write_jobs_do_not_persist_checkout_credentials(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        job_names = (
            "build",
            "verify-cli-release",
            "build-desktop",
            "verify-desktop-release",
            "audit-release-assets",
        )

        for index, name in enumerate(job_names):
            start = release.index(f"  {name}:\n")
            later_starts = [
                release.find(f"  {later}:\n", start + 1)
                for later in job_names[index + 1 :]
            ]
            later_starts = [position for position in later_starts if position >= 0]
            end = (
                min(later_starts)
                if later_starts
                else release.index("  publish-release:\n", start)
            )
            job = release[start:end]
            self.assertIn("contents: write", job, name)
            self.assertEqual(job.count("uses: actions/checkout@"), 1, name)
            self.assertEqual(job.count("persist-credentials: false"), 1, name)

    def test_candidate_execution_steps_have_no_release_token(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        verify_cli = release.split("  verify-cli-release:\n", 1)[1].split(
            "  build-desktop:\n", 1
        )[0]
        verify_desktop = release.split("  verify-desktop-release:\n", 1)[1].split(
            "  audit-release-assets:\n", 1
        )[0]
        steps = (
            (verify_cli, "Exercise the downloaded Windows CLI"),
            (verify_cli, "Exercise the downloaded macOS or Linux CLI"),
            (verify_desktop, "Exercise the Windows portable lifecycle"),
            (verify_desktop, "Exercise the Linux portable lifecycle"),
            (verify_desktop, "Exercise the macOS portable lifecycle"),
        )

        for job, name in steps:
            block = job.split(f"      - name: {name}\n", 1)[1].split(
                "      - name:", 1
            )[0]
            self.assertIn("GH_TOKEN: ''", block, name)
            self.assertIn("GITHUB_TOKEN: ''", block, name)
            self.assertNotIn("secrets.GITHUB_TOKEN", block, name)

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
        self.assertIn("if: runner.os == 'macOS'", verify_job)
        self.assertIn("plutil -lint", verify_job)
        self.assertIn("contents: write", verify_job)
        self.assertIn("release-sentinel", verify_job)
        self.assertIn("quotabot-desktop-current", verify_job)
        self.assertIn("quotabot-desktop-previous", verify_job)
        self.assertIn("releases/latest", verify_job)
        self.assertIn('gh release download "$previous_tag"', verify_job)
        self.assertIn("quotabot-previous-release", verify_job)
        self.assertIn("Previous stable release must differ", verify_job)
        self.assertIn(
            'previous_digest="$(resolve_tag_commit "$previous_tag")"', verify_job
        )
        self.assertIn('--source-digest "$previous_digest"', verify_job)
        self.assertGreaterEqual(
            verify_job.count("python tools/verify_desktop_archive.py"),
            2,
        )
        self.assertIn("refs/tags/$previous_tag", verify_job)
        self.assertNotIn(
            "Expand-Archive -LiteralPath $archive -DestinationPath $previous",
            verify_job,
        )
        self.assertNotIn('tar -xzf "$archive" -C "$previous"', verify_job)
        self.assertNotIn('ditto -x -k "$archive" "$previous"', verify_job)
        self.assertIn("Portable uninstall removed", verify_job)

    def test_each_packager_writes_the_matching_checksum_sidecar(self) -> None:
        windows = (ROOT / "tools" / "package-windows.ps1").read_text(encoding="utf-8")
        linux = (ROOT / "tools" / "package-linux.sh").read_text(encoding="utf-8")
        macos = (ROOT / "tools" / "package-macos.sh").read_text(encoding="utf-8")

        self.assertIn("quotabot-windows-x64-desktop.zip", windows)
        self.assertIn("$archive.sha256", windows)
        self.assertIn("quotabot-linux-$arch-desktop.tar.gz", linux)
        self.assertIn('> "$temporary_sidecar"', linux)
        self.assertIn("publish_package_pair", linux)
        self.assertIn("quotabot-darwin-$arch-desktop.zip", macos)
        self.assertIn('> "$temporary_sidecar"', macos)
        self.assertIn("publish_package_pair", macos)

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

    def test_normal_ci_builds_and_verifies_native_cli_archives(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("tools/package-cli.ps1", workflow)
        self.assertIn("tools/package-cli.sh", workflow)
        self.assertEqual(workflow.count("tools/verify_cli_archive.py"), 2)


if __name__ == "__main__":
    unittest.main()
