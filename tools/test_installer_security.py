import os
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class InstallerSecurityTests(unittest.TestCase):
    def test_install_smoke_uses_the_demo_environment_contract(self) -> None:
        smoke = (ROOT / ".github" / "workflows" / "install-smoke.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("--demo", smoke)
        self.assertEqual(smoke.count("doctor --json"), 3)
        self.assertEqual(smoke.count("./tools/verify-doctor.ps1 -Executable"), 2)
        clean_install = smoke.split("  clean-install:\n", 1)[1].split(
            "  upgrade-and-setup:\n", 1
        )[0]
        upgrade_and_setup = smoke.split("  upgrade-and-setup:\n", 1)[1]
        for job in (clean_install, upgrade_and_setup):
            with self.subTest(job=job.splitlines()[0]):
                header = job.split("    steps:\n", 1)[0]
                self.assertIn("QUOTABOT_DEMO: '1'", header)

    def test_install_smoke_targets_githubs_canonical_latest_release(self) -> None:
        smoke = (ROOT / ".github" / "workflows" / "install-smoke.yml").read_text(
            encoding="utf-8"
        )
        resolver = smoke.split("  resolve-releases:\n", 1)[1].split(
            "  clean-install:\n", 1
        )[0]

        self.assertIn(
            'gh api "repos/$GITHUB_REPOSITORY/releases/latest"',
            resolver,
        )
        self.assertNotIn('latest="${tags[0]}"', resolver)
        self.assertIn(r"^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$", resolver)
        self.assertIn('"$target" =~ -rc\\.', resolver)
        self.assertIn('"$tag" != "$target"', resolver)

    def test_install_smoke_pins_the_resolved_tag_during_install(self) -> None:
        smoke = (ROOT / ".github" / "workflows" / "install-smoke.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(
            smoke.count("$env:QUOTABOT_VERSION = $env:TARGET_TAG"),
            2,
        )
        self.assertEqual(
            smoke.count('QUOTABOT_VERSION="$TARGET_TAG" bash "$served"'),
            2,
        )

    def test_windows_installer_requires_checksum_sidecar(self) -> None:
        script = (ROOT / "install.ps1").read_text(encoding="utf-8")

        self.assertIn("Invoke-WebRequest -Uri $checksumUrl", script)
        self.assertNotIn("$checksumFound", script)
        self.assertNotIn("continuing with HTTPS verification only", script)

    def test_posix_installer_requires_checksum_sidecar(self) -> None:
        script = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn('curl -fsSL "${URL}.sha256" -o "$checksum_file"', script)
        self.assertNotIn('if curl -fsSL "${URL}.sha256"', script)
        self.assertNotIn("continuing with HTTPS verification only", script)
        self.assertIn("| QUOTABOT_REPO=owner/quotabot bash", script)
        self.assertNotIn("QUOTABOT_REPO=owner/quotabot curl", script)

    def test_posix_installers_use_versioned_atomic_activation(self) -> None:
        release = (ROOT / "install.sh").read_text(encoding="utf-8")
        source = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")

        self.assertIn("install_versioned_tree()", release)
        self.assertIn("install_versioned_single()", source)
        self.assertIn("install_versioned_pair()", source)
        for script, destructive_line in (
            (release, 'rm -rf "$INSTALL_ROOT"'),
            (source, 'rm -rf "$install_root"'),
        ):
            with self.subTest(destructive_line=destructive_line):
                self.assertIn('versions_name=".${target_name}-versions"', script)
                self.assertIn("activate_install_link()", script)
                self.assertIn('mv -fT "$candidate" "$target"', script)
                self.assertIn('mv -fh "$candidate" "$target"', script)
                self.assertIn("set -o noclobber", script)
                self.assertIn("kill -0", script)
                self.assertIn("validated_previous_generation()", script)
                self.assertIn('"$active_name" == */*', script)
                self.assertIn("^(generation|legacy)-[0-9]{14}-[0-9]+$", script)
                self.assertIn('! -d "$candidate" || -L "$candidate"', script)
                self.assertNotIn(destructive_line, script)

        self.assertIn("acquire_install_lock()", release)
        self.assertIn("acquire_pair_lock()", source)
        self.assertIn("rollback_versioned_pair()", source)
        self.assertIn("commit_versioned_pair()", source)
        self.assertIn("! stage_pair_item 0 || ! stage_pair_item 1", source)
        self.assertLess(
            source.index("if ! activate_pair_item 1"),
            source.index("if ! activate_pair_item 0"),
        )

    def test_source_setup_falls_back_to_release_cli(self) -> None:
        windows = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")
        posix = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")

        self.assertIn("Falling back to the release CLI.", windows)
        self.assertIn("Join-Path $root 'install.ps1'", windows)
        self.assertIn("function Install-QuotabotDartRunShim", windows)
        self.assertIn("return $null", windows)
        self.assertNotIn(
            "Dart/Flutter not found on PATH. Install Flutter",
            windows,
        )
        self.assertIn("Falling back to the release CLI.", posix)
        self.assertIn('bash "$root/install.sh"', posix)
        self.assertIn("install_dart_run_shim()", posix)
        self.assertNotIn(
            "Dart/Flutter not found. Install Flutter",
            posix,
        )
        self.assertIn("exec pwsh -NoProfile -ExecutionPolicy Bypass -File", posix)

    def test_source_setup_opens_quotabot_and_explains_auth(self) -> None:
        windows = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")
        posix = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")

        self.assertIn("function Show-QuotabotFirstRun", windows)
        self.assertIn("setup_first_run.ps1", windows)
        windows_first_run = (ROOT / "tools" / "setup_first_run.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("function Test-ReadyProvider", windows_first_run)
        self.assertIn("$Provider.stale -eq $true", windows_first_run)
        self.assertIn("$windows.Count -eq 0", windows_first_run)
        self.assertIn("signed in, quota unreadable", windows_first_run)
        self.assertIn("function Start-QuotabotAfterSetup", windows)
        self.assertIn("function Install-QuotabotPortableDesktop", windows)
        self.assertIn("quotabot-windows-x64-desktop.zip", windows)
        self.assertIn("Already live (no extra login)", windows_first_run)
        self.assertIn(
            "Start-QuotabotAfterSetup -CliExecutable $exe -AllowDesktop", windows
        )
        self.assertIn("if (-not $CliOnly)", windows)
        self.assertIn("Skipped app launch for CLI-only setup", windows)
        self.assertIn("skipped by -CliOnly", windows)
        self.assertIn("show_first_run", posix)
        self.assertIn('"$python_bin" "$script_dir/setup_first_run.py"', posix)
        self.assertNotIn("\"$python_bin\" - <<'PY'", posix)
        self.assertIn("open_quotabot_after_setup", posix)
        self.assertIn("install_portable_desktop", posix)
        self.assertIn("explicit_cli_only=1", posix)
        self.assertIn('[ "$explicit_cli_only" -eq 0 ]', posix)
        self.assertIn('[ "$explicit_cli_only" -eq 1 ]', posix)
        self.assertIn("Skipped app launch for CLI-only setup", posix)
        self.assertIn("skipped by --cli-only", posix)
        posix_first_run = (ROOT / "tools" / "setup_first_run.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("Already live (no extra login)", posix_first_run)

    def test_portable_desktop_fallback_replaces_the_selected_archive(self) -> None:
        windows = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")
        posix = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")

        windows_portable = windows.split("function Install-QuotabotPortableDesktop", 1)[
            1
        ].split("function Start-QuotabotAfterSetup", 1)[0]
        self.assertNotIn(
            "if (Test-Path -LiteralPath $installed -PathType Leaf) { return",
            windows_portable,
        )
        self.assertIn("Install-QuotabotDesktopPayload `", windows_portable)
        self.assertIn("Get-QuotabotSourceReleaseTag", windows_portable)
        self.assertIn("Get-RunningDesktopApp $installed", windows_portable)
        self.assertLess(
            windows_portable.index("Expand-Archive"),
            windows_portable.index("Get-RunningDesktopApp $installed"),
        )
        self.assertLess(
            windows_portable.index("Get-RunningDesktopApp $installed"),
            windows_portable.index("Install-QuotabotDesktopPayload `"),
        )

        windows_launch = windows.split("function Start-QuotabotAfterSetup", 1)[1].split(
            "function Invoke-QuotabotDoctor", 1
        )[0]
        self.assertIn("Get-RunningDesktopApp $appExe", windows_launch)
        self.assertIn("Desktop app already running", windows_launch)

        posix_portable = posix.split("install_portable_desktop() {", 1)[1].split(
            "open_quotabot_after_setup() {", 1
        )[0]
        self.assertNotIn('[ -x "$dest/Contents/MacOS/quotabot" ]', posix_portable)
        self.assertNotIn('[ -x "$dest/quotabot" ]', posix_portable)
        self.assertIn("install_versioned_single", posix_portable)
        self.assertIn("source_release_tag", posix_portable)
        self.assertIn('version="${version:-latest}"', posix_portable)

        self.assertIn("function Get-QuotabotSourceReleaseTag", windows)
        self.assertIn("source_release_tag()", posix)
        self.assertIn('return "v$($Matches[1])"', windows)
        self.assertIn("printf 'v%s\\n'", posix)

    def test_windows_install_smoke_uses_fail_closed_doctor_verification(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "install-smoke.yml").read_text(
            encoding="utf-8"
        )
        verifier = (ROOT / "tools" / "verify-doctor.ps1").read_text(encoding="utf-8")

        self.assertEqual(workflow.count("./tools/verify-doctor.ps1 -Executable"), 2)
        self.assertNotIn("doctor --json | ConvertFrom-Json", workflow)
        self.assertLess(
            verifier.index("$doctorExitCode = $LASTEXITCODE"),
            verifier.index("ConvertFrom-Json"),
        )
        self.assertIn("if ($doctorExitCode -ne 0)", verifier)

    def test_posix_source_setup_installs_cli_when_desktop_is_unavailable(
        self,
    ) -> None:
        script = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")

        self.assertIn("posix_desktop_prereq_reason()", script)
        self.assertIn("build_desktop_app()", script)
        self.assertIn("desktop_skipped=1", script)
        self.assertIn("cli_only=1", script)
        self.assertIn("Installing the CLI only", script)
        self.assertNotIn(
            '[ "$desktop_skipped" -eq 1 ] || [ "$cli_only" -eq 1 ]',
            script,
        )
        self.assertIn("flutter config --enable-macos-desktop", script)
        self.assertIn("flutter config --enable-linux-desktop", script)
        self.assertLess(
            script.index("posix_desktop_prereq_reason"),
            script.index("Building the quotabot CLI"),
        )
        self.assertLess(
            script.index("if build_desktop_app; then"),
            script.index("step 'Activating the CLI and desktop app'"),
        )
        self.assertIn(
            "Re-run bash tools/setup.sh after the desktop toolchain is ready to add the tray app.",
            script,
        )
        self.assertIn(
            "Re-run bash tools/setup.sh after the desktop toolchain is repaired.",
            script,
        )
        self.assertIn("On Windows, run: pwsh tools/setup.ps1", script)

    def test_posix_cli_packager_maps_spaced_dart_paths(self) -> None:
        script = (ROOT / "tools" / "package-cli.sh").read_text(encoding="utf-8")
        helper = (ROOT / "tools" / "posix-space-safe-dart.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("posix-space-safe-dart.sh", script)
        self.assertIn("quotabot_enable_space_safe_dart", script)
        self.assertIn("quotabot_restore_space_safe_dart", script)
        self.assertLess(
            script.index("quotabot_enable_space_safe_dart"),
            script.index("dart build cli --target=bin/collect.dart"),
        )
        self.assertIn("quotabot_mirror_dart_sdk()", helper)
        self.assertIn("cp -a --link", helper)
        self.assertIn("cp -al", helper)

    def test_posix_desktop_packagers_map_spaced_dart_paths(self) -> None:
        for name in ("package-linux.sh", "package-macos.sh", "setup.sh"):
            script = (ROOT / "tools" / name).read_text(encoding="utf-8")
            with self.subTest(script=name):
                self.assertIn("posix-space-safe-dart.sh", script)
                self.assertIn("quotabot_enable_space_safe_dart", script)

    def test_posix_installers_persist_local_bin_on_path(self) -> None:
        for path in (ROOT / "install.sh", ROOT / "tools" / "setup.sh"):
            script = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertIn("# quotabot PATH", script)
                self.assertIn("fish_add_path", script)
                self.assertIn('export PATH="$', script)

    def test_posix_source_setup_builds_desktop_before_cli_activation(self) -> None:
        script = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")

        cli_activation = script.index("step 'Activating the CLI and desktop app'")
        for build in (
            "flutter build macos --release --no-pub",
            "flutter build linux --release --no-pub",
        ):
            with self.subTest(build=build):
                self.assertLess(script.index(build), cli_activation)

    def test_posix_path_shim_is_replaced_only_after_it_is_complete(self) -> None:
        for path in (ROOT / "install.sh", ROOT / "tools" / "setup.sh"):
            script = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertRegex(script, r'wrapper_tmp="?\$\(mktemp ')
                self.assertLess(
                    script.index('cat > "$wrapper_tmp"'),
                    script.index('mv -f "$wrapper_tmp"'),
                )

    def test_windows_installers_use_transactional_payload_replacement(self) -> None:
        for path in (ROOT / "install.ps1", ROOT / "tools" / "setup.ps1"):
            script = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertIn("function Install-QuotabotPayload", script)
                self.assertIn(
                    "$versionsRoot = Join-Path $InstallRoot 'cli-versions'", script
                )
                self.assertIn('".quotabot-payload-new-$transaction"', script)
                self.assertIn('".quotabot-bin-link-new-$transaction"', script)
                self.assertIn('".quotabot-bin-previous-$transaction"', script)
                self.assertIn("[IO.FileShare]::None", script)
                self.assertIn("New-Item -ItemType Junction", script)
                self.assertIn(
                    "Refusing to use a link as the CLI generation directory",
                    script,
                )
                if path.name == "setup.ps1":
                    self.assertIn("-Target $State.VersionBin", script)
                    self.assertIn("-Target $State.VersionLib", script)
                    self.assertIn(
                        "Move-Item -LiteralPath $State.BackupBin -Destination $State.BinDst",
                        script,
                    )
                    self.assertLess(
                        script.index(
                            "Move-Item -LiteralPath $State.StagedBinLink -Destination $State.BinDst"
                        ),
                        script.index(
                            "Move-Item -LiteralPath $State.LibDst -Destination $State.BackupLib"
                        ),
                    )
                    self.assertIn(
                        "$rollbackComplete = $rollbackErrors.Count -eq 0", script
                    )
                    self.assertIn(
                        "if ($cli.VersionStaged) { Remove-TransactionPath",
                        script,
                    )
                else:
                    self.assertIn("-Target $versionBin", script)
                    self.assertIn("-Target $versionLib", script)
                    self.assertIn(
                        "Move-Item -LiteralPath $backupBin -Destination $binDst",
                        script,
                    )
                    self.assertLess(
                        script.index("[IO.File]::Open("),
                        script.index(
                            "Copy-Item -LiteralPath (Join-Path $SourceRoot 'bin')"
                        ),
                    )
                    self.assertLess(
                        script.index(
                            "Move-Item -LiteralPath $stagedBinLink -Destination $binDst"
                        ),
                        script.index(
                            "Move-Item -LiteralPath $libDst -Destination $backupLib"
                        ),
                    )
                    self.assertIn("$rollbackComplete = $true", script)
                    self.assertIn("if ($rollbackComplete -and $versionStaged", script)
                self.assertIn("$candidateExe", script)
                self.assertIn("$candidate.LinkType", script)
                self.assertIn("$candidate.Name -notmatch '^[0-9a-f]{32}$'", script)
                self.assertIn("The old CLI generation is still in use", script)
                self.assertIn("rollback was incomplete", script)
                self.assertNotIn(
                    "if (Test-Path -LiteralPath $binDst) { Remove-Item",
                    script,
                )

    def test_windows_source_setup_pairs_cli_and_desktop_activation(self) -> None:
        script = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")
        transaction = script.split("function Invoke-QuotabotPayloadTransaction", 1)[
            1
        ].split("function Install-QuotabotPayload", 1)[0]

        self.assertIn("function Install-QuotabotPayloadPair", script)
        self.assertIn(
            "[Array]::Sort($lockPaths, [StringComparer]::OrdinalIgnoreCase)",
            transaction,
        )
        self.assertIn("'.quotabot-install.lock'", transaction)
        self.assertIn("'.quotabot-desktop-install.lock'", transaction)
        stage_cli = transaction.index("if ($cli) { Stage-CliPayload -State $cli }")
        stage_desktop = transaction.index(
            "if ($desktop) { Stage-DesktopPayload -State $desktop }"
        )
        activate_desktop = transaction.index(
            "if ($desktop) { Activate-DesktopPayload -State $desktop }"
        )
        activate_cli = transaction.index(
            "if ($cli) { Activate-CliPayload -State $cli }"
        )
        self.assertLess(stage_cli, activate_desktop)
        self.assertLess(stage_desktop, activate_desktop)
        self.assertLess(activate_desktop, activate_cli)
        self.assertIn("Restore-CliPayload -State $cli", transaction)
        self.assertIn("Restore-DesktopPayload -State $desktop", transaction)
        flutter_build = script.index(
            "-Arguments @('build', 'windows', '--release', '--no-pub')"
        )
        self.assertLess(
            flutter_build,
            script.index("Install-QuotabotPayloadPair `"),
        )
        self.assertIn("if ($CliOnly -or $NoApp)", script)

    def test_windows_source_setup_builds_then_verifies_before_normal_app_restart(
        self,
    ) -> None:
        script = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")

        flutter_build = script.index(
            "-Arguments @('build', 'windows', '--release', '--no-pub')"
        )
        self.assertLess(
            flutter_build,
            script.index("Stopping the running desktop app for activation"),
        )
        self.assertIn("$restartRequested = $true", script)
        self.assertIn("$desktopFailure = $_", script)
        self.assertIn("if ($restartRequested)", script)
        self.assertIn("if ($desktopActivated)", script)
        self.assertIn("function Restart-QuotabotDesktopAfterSetup", script)
        self.assertIn("@($RestartCandidates) + @($InstalledAppExe)", script)
        self.assertIn("@($InstalledAppExe) + @($RestartCandidates)", script)
        self.assertIn("Start-Process `", script)
        self.assertIn("Restarted the newly installed desktop app after setup", script)
        self.assertIn("Restarted the prior desktop app after setup failed", script)
        desktop_flow = script.split("if ($CliOnly -or $NoApp)", 1)[1]
        doctor = desktop_flow.index("Invoke-QuotabotDoctor -Executable $exe")
        restart = desktop_flow.index("Restart-QuotabotDesktopAfterSetup `")
        self.assertLess(doctor, restart)
        self.assertIn("$doctorVerifiedBeforeDesktopRestart = $true", desktop_flow)
        self.assertIn("if (-not $doctorVerifiedBeforeDesktopRestart)", script)
        self.assertIn("if ($doctorExitCode -ne 0)", script)
        self.assertIn(
            'throw "Unable to run installed quotabot doctor:',
            script,
        )
        self.assertNotIn(
            "doctor reported an issue (this is expected if no provider tools have run yet)",
            script,
        )

    def test_windows_data_reset_preserves_the_active_cli_generation(self) -> None:
        setup = (ROOT / "docs" / "SETUP.md").read_text(encoding="utf-8")
        reset = setup.split("### Reset all local quotabot data", 1)[1].split(
            "## Where quotabot stores its data", 1
        )[0]

        self.assertIn("-notin", reset)
        for retained in ("'bin'", "'lib'", "'cli-versions'", "'desktop'"):
            self.assertIn(retained, reset)

    def test_windows_release_installer_uses_one_unique_temp_workspace(self) -> None:
        script = (ROOT / "install.ps1").read_text(encoding="utf-8")

        self.assertIn('"quotabot-install-$([guid]::NewGuid())"', script)
        self.assertIn("$downloadPath = Join-Path $workPath", script)
        self.assertIn("$checksumPath = Join-Path $workPath", script)
        self.assertIn("$extractPath = Join-Path $workPath", script)
        self.assertNotIn('Join-Path $env:TEMP "$assetName.download"', script)
        self.assertNotIn('Join-Path $env:TEMP "$assetName.sha256"', script)

    def test_release_installers_validate_exact_rollback_tags(self) -> None:
        posix = (ROOT / "install.sh").read_text(encoding="utf-8")
        windows = (ROOT / "install.ps1").read_text(encoding="utf-8")

        self.assertIn('VERSION="${QUOTABOT_VERSION:-latest}"', posix)
        self.assertIn(r"^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$", posix)
        self.assertIn("releases/download/${VERSION}/${ASSET}", posix)
        self.assertIn("$env:QUOTABOT_VERSION", windows)
        self.assertIn(r"'^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'", windows)
        self.assertIn("releases/download/$version/$assetName", windows)

    def test_invalid_rollback_tag_fails_before_download(self) -> None:
        environment = os.environ.copy()
        environment["QUOTABOT_VERSION"] = "../../not-a-tag"
        if os.name == "nt":
            command = [
                "pwsh",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "install.ps1"),
            ]
        else:
            bash = shutil.which("bash")
            self.assertIsNotNone(bash)
            command = [bash, str(ROOT / "install.sh")]

        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        output = completed.stdout + completed.stderr
        self.assertIn("Invalid QUOTABOT_VERSION", output)
        self.assertNotIn("Downloading quotabot-", output)

    def test_windows_space_safe_dart_does_not_use_world_writable_roots(self) -> None:
        script = (ROOT / "tools" / "windows-space-safe-dart.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Join-Path $env:LOCALAPPDATA 'quotabot-build'", script)
        self.assertIn("Join-Path $env:TEMP 'quotabot-build'", script)
        self.assertNotIn("Join-Path $env:ProgramData 'quotabot-build'", script)
        self.assertNotIn("Join-Path $env:SystemDrive 'quotabot-build'", script)

    def test_windows_desktop_packager_uses_space_safe_flutter(self) -> None:
        script = (ROOT / "tools" / "package-windows.ps1").read_text(encoding="utf-8")
        self.assertIn("Enable-QuotabotSpaceSafeDart", script)
        self.assertIn("-IncludeFlutter", script)
        self.assertIn("Invoke-QuotabotFlutter", script)

    def test_package_helpers_preserve_old_artifacts_until_new_pair_is_ready(
        self,
    ) -> None:
        posix_helper = (ROOT / "tools" / "package-pair.sh").read_text(encoding="utf-8")
        self.assertIn('backup_archive="$workspace/previous-archive"', posix_helper)
        self.assertIn('backup_sidecar="$workspace/previous-sidecar"', posix_helper)
        self.assertIn('lock_path="$archive.quotabot-package.lock"', posix_helper)
        self.assertIn("set -o noclobber", posix_helper)
        self.assertIn('mv "$backup_archive" "$archive"', posix_helper)
        self.assertIn('mv "$backup_sidecar" "$sidecar"', posix_helper)

        for name in ("package-cli.sh", "package-linux.sh", "package-macos.sh"):
            script = (ROOT / "tools" / name).read_text(encoding="utf-8")
            with self.subTest(script=name):
                self.assertIn(".quotabot-package.XXXXXX", script)
                self.assertIn(
                    'temporary_sidecar="$package_workspace/$asset.sha256"', script
                )
                self.assertIn('package-pair.sh"', script)
                self.assertIn("publish_package_pair", script)
                self.assertNotIn('rm -f "$out" "$out.sha256"', script)

        windows_helper = (ROOT / "tools" / "package-pair.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("$backupArchive", windows_helper)
        self.assertIn("$backupSidecar", windows_helper)
        self.assertIn("[IO.FileShare]::None", windows_helper)
        self.assertIn("previous archive and checksum were restored", windows_helper)

        for name in ("package-cli.ps1", "package-windows.ps1"):
            script = (ROOT / "tools" / name).read_text(encoding="utf-8")
            with self.subTest(script=name):
                self.assertIn(".quotabot-package-$([guid]::NewGuid())", script)
                self.assertIn("$temporarySidecar", script)
                self.assertIn("package-pair.ps1", script)
                self.assertIn("Publish-QuotabotPackagePair", script)
                self.assertNotIn(
                    "Remove-Item -LiteralPath $out -Force",
                    script,
                )

    def test_windows_desktop_packager_rejects_non_x64_hosts(self) -> None:
        script = (ROOT / "tools" / "package-windows.ps1").read_text(encoding="utf-8")

        self.assertIn("windows-architecture.ps1", script)
        self.assertIn("$windowsArch = Get-QuotabotWindowsArchitecture", script)
        self.assertIn("if ($windowsArch -ne 'x64')", script)
        self.assertIn("Refusing to label a different build as x64", script)

    def test_macos_source_setup_installs_the_built_app(self) -> None:
        script = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        building = (ROOT / "docs" / "BUILDING.md").read_text(encoding="utf-8")

        self.assertIn('applications="$HOME/Applications"', script)
        self.assertIn('installed_app="$applications/quotabot.app"', script)
        self.assertIn('ditto "$source" "$staging"', script)
        self.assertIn('desktop_target="$installed_app"', script)
        self.assertIn("install_versioned_pair \\", script)
        self.assertIn("[Building from source](docs/BUILDING.md)", readme)
        self.assertIn("macOS\ninstalls `~/Applications/quotabot.app`", building)

    def test_readme_demo_refreshes_pinned_flutter_build_state(self) -> None:
        script = (ROOT / "tools" / "generate_readme_demo.py").read_text(
            encoding="utf-8"
        )

        clean_at = script.index('_run([flutter, "clean"]')
        dependencies_at = script.index(
            '_run([flutter, "pub", "get", "--enforce-lockfile"]'
        )
        build_at = script.index(
            '_run([flutter, "build", target, "--debug", "--no-pub"]'
        )
        self.assertLess(clean_at, dependencies_at)
        self.assertLess(dependencies_at, build_at)
        self.assertIn("FRAME_DURATION_MS = 3000", script)
        self.assertIn("duration=[FRAME_DURATION_MS] * len(paletted)", script)

    def test_linux_source_setup_installs_a_stable_desktop_bundle(self) -> None:
        script = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")
        building = (ROOT / "docs" / "BUILDING.md").read_text(encoding="utf-8")
        smoke = (ROOT / ".github" / "workflows" / "install-smoke.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn('installed_bundle="$HOME/.local/share/quotabot-desktop"', script)
        self.assertIn('desktop_target="$installed_bundle"', script)
        self.assertIn("install_versioned_pair \\", script)
        self.assertIn('"$installed_bundle/quotabot" "$desktop"', script)
        self.assertNotIn('"$bundle/quotabot" "$desktop"', script)
        self.assertIn("~/.local/share/quotabot-desktop", building)
        self.assertIn(
            '[[ "$target" == "$HOME/.local/share/quotabot-desktop/quotabot" ]]',
            smoke,
        )

    def test_windows_cli_packager_maps_spaced_dart_paths(self) -> None:
        script = (ROOT / "tools" / "package-cli.ps1").read_text(encoding="utf-8")
        helper = (ROOT / "tools" / "windows-space-safe-dart.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("windows-space-safe-dart.ps1", script)
        self.assertIn("Enable-QuotabotSpaceSafeDart", script)
        self.assertIn("Disable-QuotabotSpaceSafeDart -State $spaceSafe", script)
        self.assertIn("& $dart build cli --target=bin\\collect.dart", script)
        self.assertLess(
            script.index("Enable-QuotabotSpaceSafeDart"),
            script.index("& $dart build cli --target=bin\\collect.dart"),
        )
        self.assertIn("is not recognized", helper)
        self.assertIn("Copy-QuotabotDirectoryAsHardLinks", helper)
        self.assertIn("New-Item -ItemType HardLink", helper)
        self.assertIn("Platform.resolvedExecutable", helper)

    def test_windows_source_setup_installs_cli_when_desktop_atl_is_missing(
        self,
    ) -> None:
        script = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")
        prereqs = (ROOT / "tools" / "windows-build-prereqs.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("function Test-WindowsDesktopAtlAvailable", prereqs)
        self.assertIn("function Test-WindowsDesktopPluginLinksAvailable", prereqs)
        self.assertIn("function Get-WindowsAtlHeaderForInstall", prereqs)
        self.assertIn("Get-WindowsDesktopBuildPrereqStatus", script)
        self.assertIn("Test-WindowsDesktopPluginLinksAvailable", script)
        self.assertIn("$desktopSkipped = $true", script)
        self.assertIn("$NoApp = $true", script)
        self.assertIn("Desktop skipped: Visual Studio C++ ATL headers", script)
        self.assertIn("plugin symlink permission is unavailable", script)
        self.assertLess(
            script.index("Get-WindowsDesktopBuildPrereqStatus"),
            script.index("Building the quotabot CLI"),
        )
        self.assertLess(
            script.index("Get-WindowsDesktopBuildPrereqStatus"),
            script.index("-Arguments @('build', 'windows', '--release', '--no-pub')"),
        )
        self.assertIn(
            "add Visual Studio C++ ATL later for a source-built tray app",
            script,
        )
        self.assertIn(
            "-Arguments @('config', '--enable-windows-desktop')",
            script,
        )
        self.assertIn(
            "Desktop skipped: $($_.Exception.Message). Installing the CLI only.",
            script,
        )
        self.assertIn("if ($desktopActivated) { throw }", script)

    def test_setup_docs_name_the_source_setup_scripts(self) -> None:
        setup = (ROOT / "docs" / "SETUP.md").read_text(encoding="utf-8")
        building = (ROOT / "docs" / "BUILDING.md").read_text(encoding="utf-8")
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")

        self.assertIn("pwsh tools/setup.ps1", setup)
        self.assertIn("bash tools/setup.sh", setup)
        self.assertIn("C++ ATL", setup)
        self.assertIn("spaces", setup.lower())
        self.assertIn("still installs the CLI", building)
        self.assertIn("checksum-verified release CLI", setup)
        self.assertIn("desktop os build tools", setup.lower())
        self.assertIn("pwsh tools/setup.ps1", agents)
        self.assertIn("desktop OS build tools", agents)
        self.assertIn("macOS", agents)
        self.assertIn("Linux", agents)

    def test_windows_source_setup_installs_a_stable_desktop_bundle(self) -> None:
        script = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")
        building = (ROOT / "docs" / "BUILDING.md").read_text(encoding="utf-8")
        smoke = (ROOT / ".github" / "workflows" / "install-smoke.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("function Install-QuotabotDesktopPayload", script)
        self.assertIn(".quotabot-desktop-new-$transaction", script)
        self.assertIn(".quotabot-desktop-previous-$transaction", script)
        self.assertIn("-ExePath $installedAppExe", script)
        self.assertNotIn("-ExePath $builtAppExe", script)
        self.assertIn(r"%LOCALAPPDATA%\quotabot\desktop", building)
        self.assertIn("quotabot\\desktop\\quotabot.exe", smoke)

    @unittest.skipUnless(os.name == "nt", "PowerShell helper test is Windows-only")
    def test_windows_space_safe_dart_helper_behavior(self) -> None:
        completed = subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "tools" / "test-windows-space-safe-dart.ps1"),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

        self.assertEqual(
            completed.returncode,
            0,
            completed.stdout + completed.stderr,
        )

    @unittest.skipUnless(os.name == "nt", "PowerShell transaction test is Windows-only")
    def test_windows_install_transaction_behavior(self) -> None:
        completed = subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "tools" / "test-install-transaction.ps1"),
            ],
            cwd=ROOT,
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

    @unittest.skipUnless(os.name == "nt", "PowerShell doctor test is Windows-only")
    def test_windows_doctor_verifier_rejects_nonzero_native_exit(self) -> None:
        completed = subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "tools" / "test-verify-doctor.ps1"),
            ],
            cwd=ROOT,
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

    def test_package_pair_transaction_behavior(self) -> None:
        if os.name == "nt":
            command = [
                "pwsh",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "tools" / "test-package-pair.ps1"),
            ]
        else:
            bash = shutil.which("bash")
            self.assertIsNotNone(bash)
            command = [bash, str(ROOT / "tools" / "test-package-pair.sh")]

        completed = subprocess.run(
            command,
            cwd=ROOT,
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

    def test_posix_space_safe_dart_helper_behavior(self) -> None:
        bash = shutil.which("bash")
        if os.name == "nt":
            program_files = Path(os.environ.get("ProgramFiles", "C:/Program Files"))
            candidate = program_files / "Git" / "bin" / "bash.exe"
            if candidate.is_file():
                bash = str(candidate)
        if bash is None:
            self.skipTest("bash is required for the POSIX Dart helper test")

        completed = subprocess.run(
            [bash, str(ROOT / "tools" / "test-posix-space-safe-dart.sh")],
            cwd=ROOT,
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

    def test_posix_install_transaction_behavior(self) -> None:
        bash = shutil.which("bash")
        if os.name == "nt":
            self.skipTest(
                "POSIX install transaction harness needs GNU mv -T; "
                "Linux CI covers the activation rollback"
            )
        if bash is None:
            self.skipTest("bash is required for the POSIX installer test")

        environment = os.environ.copy()
        completed = subprocess.run(
            [bash, str(ROOT / "tools" / "test-posix-install-transaction.sh")],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

        self.assertEqual(
            completed.returncode,
            0,
            completed.stdout + completed.stderr,
        )

    @unittest.skipIf(os.name == "nt", "POSIX uninstall test needs a native host")
    def test_posix_uninstall_behavior(self) -> None:
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        completed = subprocess.run(
            [bash, str(ROOT / "tools" / "test-posix-uninstall.sh")],
            cwd=ROOT,
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


if __name__ == "__main__":
    unittest.main()
