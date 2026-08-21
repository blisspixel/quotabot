"""Static policy tests for prebuilt desktop release publication."""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
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
        self.assertIn(
            "needs: [create-release, build-desktop, package-windows-desktop]",
            workflow,
        )
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
            "          - os: macos-latest\n"
            "            script: bash tools/package-macos.sh\n"
            "            archive: release/quotabot-darwin-arm64-desktop.zip\n"
            "          - os: ubuntu-latest\n"
            "            script: bash tools/package-linux.sh\n"
            "            archive: release/quotabot-linux-x64-desktop.tar.gz\n",
            matrix,
        )
        windows_job = workflow.split("  build-windows-desktop-unsigned:\n", 1)[1].split(
            "  sign-windows-desktop:\n", 1
        )[0]
        self.assertIn("runs-on: windows-latest", windows_job)
        self.assertIn("./tools/package-windows.ps1 -NoArchive", windows_job)

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

        self.assertIn(
            "needs: [create-release, build, package-windows-cli]",
            verify_job,
        )
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
        job_order = (
            "preflight",
            "quality-gate",
            "codeql-gate",
            "secret-scan-gate",
            "create-release",
            "build",
            "build-windows-cli-unsigned",
            "sign-windows-cli",
            "package-windows-cli",
            "verify-cli-release",
            "build-desktop",
            "build-windows-desktop-unsigned",
            "sign-windows-desktop",
            "package-windows-desktop",
            "verify-desktop-release",
            "audit-release-assets",
            "publish-release",
        )
        job_names = (
            "build",
            "package-windows-cli",
            "verify-cli-release",
            "build-desktop",
            "package-windows-desktop",
            "verify-desktop-release",
            "audit-release-assets",
        )

        for name in job_names:
            index = job_order.index(name)
            start = release.index(f"  {name}:\n")
            end = (
                release.index(f"  {job_order[index + 1]}:\n", start)
                if index + 1 < len(job_order)
                else len(release)
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
        apt_at = verify_job.index("Install Linux desktop runtime prerequisites")
        readiness_at = verify_job.index("desktop_readiness_smoke.py")
        self.assertLess(download_at, checksum_at)
        self.assertLess(checksum_at, attestation_at)
        self.assertLess(attestation_at, apt_at)
        self.assertLess(apt_at, readiness_at)
        header = verify_job.split("steps:", 1)[0]
        self.assertIn("timeout-minutes: 45", header)
        self.assertIn("tools/install-linux-desktop-prereqs.sh", verify_job)
        helper = (ROOT / "tools" / "install-linux-desktop-prereqs.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("timeout 90s sudo apt-get", helper)
        self.assertIn("timeout 180s sudo apt-get install", helper)
        self.assertIn("three bounded attempts", helper)
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("tools/install-linux-desktop-prereqs.sh", ci)
        desktop_build = workflow.split("  build-desktop:\n", 1)[1].split(
            "  verify-desktop-release:\n", 1
        )[0]
        self.assertIn("tools/install-linux-desktop-prereqs.sh", desktop_build)
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

        windows_lifecycle = verify_job.split(
            "      - name: Exercise the Windows portable lifecycle\n", 1
        )[1].split("      - name:", 1)[0]
        self.assertIn("function Remove-PortableTree", windows_lifecycle)
        self.assertIn(
            "for ($attempt = 1; $attempt -le 10; $attempt++)",
            windows_lifecycle,
        )
        self.assertIn("if ($attempt -eq 10) { throw }", windows_lifecycle)
        self.assertIn("Start-Sleep -Milliseconds 1000", windows_lifecycle)
        self.assertEqual(
            windows_lifecycle.count("Remove-PortableTree -LiteralPath"),
            2,
        )
        self.assertIn("quotabot-windows-current-readiness.json", verify_job)
        self.assertIn("quotabot-windows-previous-readiness.json", verify_job)
        self.assertIn("quotabot-linux-current-readiness.json", verify_job)
        self.assertIn("quotabot-linux-previous-readiness.json", verify_job)
        self.assertIn("if: always() &&", verify_job)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77", verify_job)

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

    def test_cli_packagers_expose_a_build_sign_package_boundary(self) -> None:
        windows = (ROOT / "tools" / "package-cli.ps1").read_text(encoding="utf-8")
        posix = (ROOT / "tools" / "package-cli.sh").read_text(encoding="utf-8")

        for option in ("[switch]$NoArchive", "[switch]$PackageOnly"):
            self.assertIn(option, windows)
        self.assertIn("if ($NoArchive -and $PackageOnly)", windows)
        self.assertIn("if (-not $PackageOnly)", windows)
        self.assertIn("if ($NoArchive)", windows)
        self.assertLess(
            windows.index("if ($NoArchive -and $PackageOnly)"),
            windows.index("Enable-QuotabotSpaceSafeDart"),
        )
        package_only = windows.split("if (-not $PackageOnly)", 1)[1]
        self.assertIn("dart build cli", package_only)
        self.assertIn("CLI bundle ready", windows)
        self.assertIn("Package-only mode requires", windows)

        for option in ("--no-archive", "--package-only"):
            self.assertIn(option, posix)
        self.assertIn('if [ "$archive" -eq 0 ] && [ "$package_only" -eq 1 ]', posix)
        self.assertIn('if [ "$package_only" -eq 0 ]', posix)
        self.assertIn('if [ "$archive" -eq 0 ]', posix)
        self.assertLess(
            posix.index('if [ "$archive" -eq 0 ] && [ "$package_only" -eq 1 ]'),
            posix.index("command -v dart"),
        )
        self.assertIn("CLI bundle ready", posix)
        self.assertIn("Package-only mode requires", posix)

    def test_desktop_packagers_can_archive_without_rebuilding(self) -> None:
        windows = (ROOT / "tools" / "package-windows.ps1").read_text(encoding="utf-8")
        macos = (ROOT / "tools" / "package-macos.sh").read_text(encoding="utf-8")

        self.assertIn("[switch]$PackageOnly", windows)
        self.assertIn("if ($NoArchive -and $PackageOnly)", windows)
        self.assertIn("if (-not $PackageOnly)", windows)
        self.assertLess(
            windows.index("if ($NoArchive -and $PackageOnly)"),
            windows.index("Get-Command flutter"),
        )
        self.assertIn("Using existing Windows release bundle", windows)
        self.assertIn("Package-only mode requires", windows)

        self.assertIn("--package-only", macos)
        self.assertIn('if [ "$archive" -eq 0 ] && [ "$package_only" -eq 1 ]', macos)
        self.assertIn('if [ "$package_only" -eq 0 ]', macos)
        self.assertLess(
            macos.index('if [ "$archive" -eq 0 ] && [ "$package_only" -eq 1 ]'),
            macos.index("command -v flutter"),
        )
        self.assertIn("Using existing macOS release bundle", macos)
        self.assertIn("Package-only mode requires", macos)

    @unittest.skipUnless(os.name == "nt", "Windows packaging requires Windows")
    def test_windows_package_only_preserves_existing_candidate_bytes(self) -> None:
        powershell = shutil.which("pwsh")
        if powershell is None:
            self.skipTest("PowerShell 7 is unavailable")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            for name in (
                "package-cli.ps1",
                "package-windows.ps1",
                "package-pair.ps1",
                "windows-architecture.ps1",
                "windows-build-prereqs.ps1",
            ):
                shutil.copy2(ROOT / "tools" / name, tools / name)

            cli_bytes = b"exact normalized CLI candidate\n"
            desktop_bytes = b"exact desktop candidate\n"
            cli = (
                root
                / "collector"
                / "build"
                / "quotabot_cli_release"
                / "bundle"
                / "bin"
                / "quotabot.exe"
            )
            desktop = (
                root
                / "app"
                / "build"
                / "windows"
                / "x64"
                / "runner"
                / "Release"
                / "quotabot.exe"
            )
            cli.parent.mkdir(parents=True)
            desktop.parent.mkdir(parents=True)
            cli.write_bytes(cli_bytes)
            desktop.write_bytes(desktop_bytes)

            environment = os.environ.copy()
            environment["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")
            for script in ("package-cli.ps1", "package-windows.ps1"):
                completed = subprocess.run(
                    [powershell, "-NoProfile", "-File", tools / script, "-PackageOnly"],
                    cwd=root,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    completed.stdout + completed.stderr,
                )

            cli_archive = root / "release" / "quotabot-windows-x64.zip"
            desktop_archive = root / "release" / "quotabot-windows-x64-desktop.zip"
            with zipfile.ZipFile(cli_archive) as archive:
                self.assertEqual(archive.read("bin/quotabot.exe"), cli_bytes)
            with zipfile.ZipFile(desktop_archive) as archive:
                self.assertEqual(archive.read("quotabot.exe"), desktop_bytes)

            for archive in (cli_archive, desktop_archive):
                expected = hashlib.sha256(archive.read_bytes()).hexdigest()
                sidecar = Path(f"{archive}.sha256").read_text(encoding="utf-8")
                self.assertEqual(sidecar, f"{expected}  {archive.name}")

    @unittest.skipIf(os.name == "nt", "POSIX packaging requires macOS or Linux")
    def test_posix_cli_package_only_preserves_existing_candidate_bytes(self) -> None:
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("Bash is unavailable")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            for name in ("package-cli.sh", "package-pair.sh"):
                shutil.copy2(ROOT / "tools" / name, tools / name)

            cli_bytes = b"exact normalized POSIX CLI candidate\n"
            cli = (
                root
                / "collector"
                / "build"
                / "quotabot_cli_release"
                / "bundle"
                / "bin"
                / "quotabot"
            )
            cli.parent.mkdir(parents=True)
            cli.write_bytes(cli_bytes)
            cli.chmod(0o755)

            completed = subprocess.run(
                [bash, tools / "package-cli.sh", "--package-only"],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                completed.stdout + completed.stderr,
            )

            archives = list((root / "release").glob("quotabot-*.tar.gz"))
            self.assertEqual(len(archives), 1)
            archive = archives[0]
            with tarfile.open(archive, "r:gz") as package:
                member = package.extractfile("./bin/quotabot")
                self.assertIsNotNone(member)
                self.assertEqual(
                    member.read() if member is not None else None, cli_bytes
                )
            expected = hashlib.sha256(archive.read_bytes()).hexdigest()
            sidecar = Path(f"{archive}.sha256").read_text(encoding="utf-8")
            self.assertEqual(sidecar, f"{expected}  {archive.name}")

    def test_unsigned_launch_guidance_never_authorizes_protection_bypass(
        self,
    ) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        distribution = (ROOT / "docs" / "DESKTOP-DISTRIBUTION.md").read_text(
            encoding="utf-8"
        )
        normalized_distribution = " ".join(distribution.split())

        self.assertIn("checksum-verified CLI release", readme)
        self.assertIn("For GitHub build provenance", normalized_distribution)
        self.assertIn("Do not bypass SmartScreen.", normalized_distribution)
        self.assertIn(
            "Checksums and GitHub provenance do not establish Windows publisher identity.",
            normalized_distribution,
        )
        self.assertNotIn("Do not bypass a warning until", normalized_distribution)
        self.assertIn("Do not remove quarantine metadata", normalized_distribution)

    def test_windows_native_signing_inventory_binds_archives(
        self,
    ) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(ci.count("native_code_inventory.py"), 4)
        self.assertEqual(release.count("native_code_inventory.py"), 12)
        self.assertNotIn("sign_windows.py", ci)
        self.assertNotIn("sign_windows.py", release)
        self.assertEqual(release.count("create_windows_signing_catalog.py"), 4)
        self.assertEqual(
            release.count("azure/login@f5d393ae46f8fde4be8b75f32e3fc50e654ad0ca"),
            2,
        )
        self.assertEqual(
            release.count(
                "Azure/artifact-signing-action@c7ab2a863ab5f9a846ddb8265964877ef296ee82"
            ),
            2,
        )
        self.assertEqual(ci.count("verify_windows_signatures.py"), 0)
        self.assertEqual(release.count("verify_windows_signatures.py"), 6)
        for workflow in (ci, release):
            self.assertNotIn("--platform macos", workflow)

        self.assertEqual(
            ci.count("--platform windows --surface cli --architecture x64"),
            2,
        )
        self.assertEqual(
            ci.count("--platform windows --surface desktop --architecture x64"),
            2,
        )
        self.assertEqual(ci.count("--expect-manifest"), 2)
        self.assertEqual(
            release.count("--platform windows --surface cli --architecture x64"),
            6,
        )
        self.assertEqual(
            release.count("--platform windows --surface desktop --architecture x64"),
            6,
        )
        self.assertEqual(release.count("--expect-manifest"), 6)

        cli_unsigned = release.split("  build-windows-cli-unsigned:\n", 1)[1].split(
            "  sign-windows-cli:\n", 1
        )[0]
        cli_sign = release.split("  sign-windows-cli:\n", 1)[1].split(
            "  package-windows-cli:\n", 1
        )[0]
        cli_package = release.split("  package-windows-cli:\n", 1)[1].split(
            "  verify-cli-release:\n", 1
        )[0]
        desktop_unsigned = release.split("  build-windows-desktop-unsigned:\n", 1)[
            1
        ].split("  sign-windows-desktop:\n", 1)[0]
        desktop_sign = release.split("  sign-windows-desktop:\n", 1)[1].split(
            "  package-windows-desktop:\n", 1
        )[0]
        desktop_package = release.split("  package-windows-desktop:\n", 1)[1].split(
            "  verify-desktop-release:\n", 1
        )[0]

        for unsigned, sign, package, verifier in (
            (
                cli_unsigned,
                cli_sign,
                cli_package,
                "verify_cli_archive.py",
            ),
            (
                desktop_unsigned,
                desktop_sign,
                desktop_package,
                "verify_desktop_archive.py",
            ),
        ):
            self.assertIn("-NoArchive", unsigned)
            self.assertIn("unsigned-inventory.json", unsigned)
            self.assertIn("create_windows_signing_catalog.py", unsigned)
            self.assertIn("actions/upload-artifact@", unsigned)
            self.assertIn("include-hidden-files: true", unsigned)
            self.assertIn("if-no-files-found: error", unsigned)
            self.assertNotIn("environment: release-signing", unsigned)
            self.assertNotIn("id-token: write", unsigned)
            self.assertNotIn("azure/login@", unsigned)
            self.assertNotIn("Azure/artifact-signing-action@", unsigned)
            self.assertNotIn("PFX", unsigned)
            self.assertNotIn("PASSWORD", unsigned)

            validate_at = sign.index("--expect-manifest")
            catalog_at = sign.index("create_windows_signing_catalog.py")
            azure_login_at = sign.index("azure/login@")
            sign_at = sign.index("Azure/artifact-signing-action@")
            post_sign_at = sign.index("Post-signing native inventory failed")
            verify_sig_at = sign.index("verify_windows_signatures.py")
            preserve_at = sign.index("actions/upload-artifact@", sign_at)
            self.assertLess(validate_at, catalog_at)
            self.assertLess(catalog_at, azure_login_at)
            self.assertLess(azure_login_at, sign_at)
            self.assertLess(sign_at, post_sign_at)
            self.assertLess(post_sign_at, verify_sig_at)
            self.assertLess(verify_sig_at, preserve_at)
            self.assertIn("environment: release-signing", sign)
            self.assertIn("contents: read", sign)
            self.assertIn("id-token: write", sign)
            self.assertNotIn("contents: write", sign)
            self.assertNotIn("attestations: write", sign)
            self.assertNotIn("-NoArchive", sign)
            self.assertNotIn("-PackageOnly", sign)
            self.assertIn("vars.QUOTABOT_AZURE_CLIENT_ID", sign)
            self.assertIn("vars.QUOTABOT_AZURE_TENANT_ID", sign)
            self.assertIn("vars.QUOTABOT_AZURE_SUBSCRIPTION_ID", sign)
            self.assertIn("vars.QUOTABOT_AZURE_SIGNING_ENDPOINT", sign)
            self.assertIn("vars.QUOTABOT_AZURE_SIGNING_ACCOUNT", sign)
            self.assertIn("vars.QUOTABOT_AZURE_CERTIFICATE_PROFILE", sign)
            self.assertIn("vars.QUOTABOT_WINDOWS_SUBSCRIBER_EKU", sign)
            self.assertIn("files-catalog:", sign)
            self.assertIn("file-digest: SHA256", sign)
            self.assertIn(
                "timestamp-rfc3161: http://timestamp.acs.microsoft.com",
                sign,
            )
            self.assertIn("timestamp-digest: SHA256", sign)
            self.assertIn("append-signature: false", sign)
            self.assertIn("batch-size: 0", sign)
            self.assertIn("cache-dependencies: false", sign)
            self.assertIn("trace: false", sign)
            self.assertIn("exclude-environment-credential: true", sign)
            self.assertIn("exclude-azure-cli-credential: false", sign)
            self.assertIn("--expected-subscriber-eku", sign)
            self.assertNotIn("secrets.", sign[azure_login_at:sign_at])

            self.assertIn("always()", package)
            self.assertIn("result == 'skipped'", package)
            self.assertIn("result == 'success'", package)
            self.assertIn("actions/download-artifact@", package)
            self.assertIn("-PackageOnly", package)
            self.assertIn(verifier, package)
            self.assertIn("--expect-manifest", package)
            self.assertIn("--expected-subscriber-eku", package)
            self.assertIn("actions/attest-build-provenance@", package)
            self.assertIn("gh release upload", package)
            self.assertNotIn("environment: release-signing", package)
            self.assertNotIn("azure/login@", package)
            self.assertNotIn("Azure/artifact-signing-action@", package)
            self.assertNotIn("PFX", package)
            self.assertNotIn("CLIENT_SECRET", package)
            self.assertNotIn("--expected-signer-subject", package)
            self.assertNotIn("--expected-signer-thumbprint", package)

            package_at = package.index("-PackageOnly")
            verify_at = package.index(verifier)
            archive_inventory_at = package.rindex("native_code_inventory.py")
            preserve_at = package.index("actions/upload-artifact@")
            attest_at = package.index("actions/attest-build-provenance@")
            upload_at = package.index("gh release upload")
            self.assertLess(package_at, verify_at)
            self.assertLess(verify_at, archive_inventory_at)
            self.assertLess(archive_inventory_at, preserve_at)
            self.assertLess(preserve_at, attest_at)
            self.assertLess(attest_at, upload_at)

        non_windows_cli = release.split("  build:\n", 1)[1].split(
            "  build-windows-cli-unsigned:\n", 1
        )[0]
        non_windows_desktop = release.split("  build-desktop:\n", 1)[1].split(
            "  build-windows-desktop-unsigned:\n", 1
        )[0]
        for job in (non_windows_cli, non_windows_desktop):
            self.assertNotIn("environment: release-signing", job)
            self.assertNotIn("azure/login@", job)
            self.assertNotIn("Azure/artifact-signing-action@", job)

        self.assertIn("tools.test_native_code_inventory", ci)
        self.assertIn("tools.test_windows_signing_catalog", ci)

    def test_release_signing_modes_are_explicit_and_disclosed(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(release.count("environment: release-signing"), 2)
        for job_name, next_job in (
            ("sign-windows-cli", "package-windows-cli"),
            ("sign-windows-desktop", "package-windows-desktop"),
        ):
            job = release.split(f"  {job_name}:\n", 1)[1].split(f"  {next_job}:\n", 1)[
                0
            ]
            self.assertIn("environment: release-signing", job)
        self.assertNotIn(
            "environment: release-signing",
            release.split("  build:\n", 1)[1].split("  sign-windows-cli:\n", 1)[0],
        )
        self.assertNotIn(
            "environment: release-signing",
            release.split("  package-windows-cli:\n", 1)[1].split(
                "  sign-windows-desktop:\n", 1
            )[0],
        )
        self.assertNotIn(
            "environment: release-signing",
            release.split("  package-windows-desktop:\n", 1)[1],
        )
        self.assertIn(
            "unsigned|azure-artifact-signing",
            release,
        )
        self.assertIn("QUOTABOT_MACOS_SIGNING_MODE must be unsigned", release)
        self.assertIn("Native signing status:", release)
        self.assertIn("Do not bypass SmartScreen or Gatekeeper.", release)
        self.assertIn("Draft release native signing disclosure", release)
        self.assertNotIn("QUOTABOT_WINDOWS_PFX", release)

    def test_release_notes_are_curated_without_generated_attribution(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("--generate-notes", release)
        self.assertIn("changelog_notes=", release)
        self.assertIn("CHANGELOG.md has no release section", release)
        self.assertIn('--notes "$release_notes"', release)

    def test_release_signing_docs_require_azure_action_allowlist(self) -> None:
        signing = (ROOT / "docs" / "RELEASE-SIGNING.md").read_text(
            encoding="utf-8"
        )
        normalized = " ".join(signing.split())

        self.assertIn("azure/login@*", signing)
        self.assertIn("Azure/artifact-signing-action@*", signing)
        self.assertIn("full-length commit SHA pinning required", normalized)
        self.assertIn(
            "GitHub resolves every referenced action before it evaluates a job condition",
            normalized,
        )
        self.assertIn(
            "gh api repos/blisspixel/quotabot/actions/permissions/selected-actions",
            signing,
        )

    def test_downloaded_windows_draft_assets_are_natively_reverified(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        verify_cli = release.split("  verify-cli-release:\n", 1)[1].split(
            "  build-desktop:\n", 1
        )[0]
        verify_desktop = release.split("  verify-desktop-release:\n", 1)[1].split(
            "  audit-release-assets:\n", 1
        )[0]

        for job, surface, evidence_name in (
            (verify_cli, "cli", "windows-cli-draft-signature-verification"),
            (
                verify_desktop,
                "desktop",
                "windows-desktop-draft-signature-verification",
            ),
        ):
            provenance_at = job.index("gh attestation verify")
            inventory_at = job.index(
                f"native_code_inventory.py --platform windows --surface {surface}"
            )
            signature_at = job.index(
                f"verify_windows_signatures.py --manifest $manifest --surface {surface}"
            )
            preserve_at = job.index(f"name: {evidence_name}")
            self.assertLess(provenance_at, inventory_at)
            self.assertLess(inventory_at, signature_at)
            self.assertLess(signature_at, preserve_at)
            self.assertIn("--expected-subscriber-eku", job)
            self.assertIn("vars.QUOTABOT_WINDOWS_SUBSCRIBER_EKU", job)
            self.assertNotIn("--expected-signer-subject", job)
            self.assertNotIn("--expected-signer-thumbprint", job)
            self.assertIn("--receipt $receipt $expanded", job)
            preserve_context = job[max(0, preserve_at - 500) : preserve_at + 500]
            self.assertIn(
                "vars.QUOTABOT_WINDOWS_SIGNING_BACKEND == 'azure-artifact-signing'",
                preserve_context,
            )
            self.assertIn("if-no-files-found: warn", preserve_context)

        audit_job = release.split("  audit-release-assets:\n", 1)[1].split(
            "  publish-release:\n", 1
        )[0]
        self.assertIn(
            "needs: [create-release, verify-cli-release, verify-desktop-release]",
            audit_job,
        )

    def test_windows_signature_verifier_is_a_fail_closed_release_gate(
        self,
    ) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        building = (ROOT / "docs" / "BUILDING.md").read_text(encoding="utf-8")
        normalized_building = " ".join(building.split())

        self.assertIn("tools.test_verify_windows_signatures", ci)
        self.assertIn("verify_windows_signatures.py", release)
        self.assertIn("create_windows_signing_catalog.py", release)
        self.assertIn("new post-signing inventory", normalized_building)
        self.assertIn("real embedded-signed Windows fixture test", normalized_building)
        self.assertIn(
            "exactly one valid embedded Authenticode signature", normalized_building
        )
        self.assertIn("does not accept native-tool overrides", normalized_building)
        self.assertIn("TSTInfo `messageImprint` must use the SHA-256 OID", building)
        self.assertIn("timestamp_policy_unproven", building)
        self.assertIn("windows-cli-signature-verification.json", building)
        self.assertIn("New-Item -ItemType Directory -Force -Path '.agent'", building)
        self.assertIn("--receipt $receipt $candidate", building)
        self.assertNotIn("--json $candidate > $receipt", building)
        self.assertIn(
            "leaves any prior complete receipt untouched", normalized_building
        )
        self.assertIn(
            "Terminal fallback JSON appears only when the receipt itself cannot be published",
            normalized_building,
        )
        self.assertIn("`receipt_body_sha256`", building)
        self.assertIn("all other receipt fields", normalized_building)
        self.assertIn("remove `receipt_body_sha256`", normalized_building)
        self.assertIn(
            "not a signature, MAC, attestation, or proof of origin",
            normalized_building,
        )
        self.assertIn("exit status", normalized_building)
        self.assertIn("independent workflow provenance", normalized_building)
        self.assertIn(
            "On success, use the candidate and inventory digests",
            normalized_building,
        )
        self.assertIn("canonical candidate tree", normalized_building)
        self.assertIn("archive checksum", normalized_building)
        self.assertIn("`receipt_output_invalid`", building)
        self.assertIn("must not be treated as current", normalized_building)
        self.assertIn("may contain prior evidence", normalized_building)
        self.assertIn("or may not exist", normalized_building)
        self.assertIn("capture the terminal fallback", normalized_building)
        self.assertIn("SignTool and PowerShell hashes", normalized_building)
        self.assertIn("durable subscriber identity EKU", normalized_building)
        self.assertIn("stop publication", normalized_building)
        self.assertIn("allowlisted failure stage", normalized_building)
        self.assertIn("fails closed without those values", normalized_building)
        self.assertIn("v0.9.9 release artifacts remain unsigned", normalized_building)

    def test_signing_scope_names_pe_modules_and_the_standalone_macos_cli(
        self,
    ) -> None:
        roadmap = (ROOT / "ROADMAP.md").read_text(encoding="utf-8")
        building = (ROOT / "docs" / "BUILDING.md").read_text(encoding="utf-8")

        for text in (roadmap, building):
            self.assertIn("every shipped PE module", text)
            self.assertIn("standalone macOS CLI", text)
            self.assertIn("nested Mach-O", text)

    def test_normal_ci_builds_and_verifies_native_desktop_archives(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("tools/package-windows.ps1", workflow)
        self.assertIn("tools/package-linux.sh", workflow)
        self.assertIn("tools/package-macos.sh", workflow)
        self.assertEqual(workflow.count("tools/verify_desktop_archive.py"), 3)
        self.assertIn("package-windows.ps1 -NoArchive", workflow)
        self.assertIn("package-windows.ps1 -PackageOnly", workflow)
        self.assertNotIn("package-linux.sh --no-archive", workflow)
        self.assertNotIn("package-macos.sh --no-archive", workflow)
        self.assertIn("quotabot-windows-readiness.json", workflow)
        self.assertIn("quotabot-linux-readiness.json", workflow)
        self.assertIn("if: always() &&", workflow)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77", workflow)

    def test_normal_ci_builds_and_verifies_native_cli_archives(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("tools/package-cli.ps1", workflow)
        self.assertIn("tools/package-cli.sh", workflow)
        self.assertIn("package-cli.ps1 -NoArchive", workflow)
        self.assertIn("package-cli.ps1 -PackageOnly", workflow)
        self.assertNotIn("package-cli.sh --no-archive", workflow)
        self.assertEqual(workflow.count("tools/verify_cli_archive.py"), 2)


if __name__ == "__main__":
    unittest.main()
