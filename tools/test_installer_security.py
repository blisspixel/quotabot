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
        self.assertEqual(smoke.count("doctor --json"), 5)
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
        self.assertIn('"$tag" != "$latest"', resolver)

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
        self.assertLess(
            script.index("& flutter build windows --release --no-pub"),
            script.index("Install-QuotabotPayloadPair `"),
        )
        self.assertIn("if ($CliOnly -or $NoApp)", script)

    def test_windows_source_setup_builds_before_normal_app_shutdown_and_restarts_in_finally(
        self,
    ) -> None:
        script = (ROOT / "tools" / "setup.ps1").read_text(encoding="utf-8")

        self.assertLess(
            script.index("& flutter build windows --release --no-pub"),
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
        self.assertIn(r"^v[0-9]+\.[0-9]+\.[0-9]+$", posix)
        self.assertIn("releases/download/${VERSION}/${ASSET}", posix)
        self.assertIn("$env:QUOTABOT_VERSION", windows)
        self.assertIn(r"'^v[0-9]+\.[0-9]+\.[0-9]+$'", windows)
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
        self.assertIn("macOS installs the app\nunder `~/Applications`", readme)
        self.assertIn("macOS\ninstalls `~/Applications/quotabot.app`", building)

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

    def test_posix_install_transaction_behavior(self) -> None:
        bash = shutil.which("bash")
        if os.name == "nt":
            program_files = Path(os.environ.get("ProgramFiles", "C:/Program Files"))
            candidate = program_files / "Git" / "bin" / "bash.exe"
            if candidate.is_file():
                bash = str(candidate)
        if bash is None:
            self.skipTest("bash is required for the POSIX installer test")

        environment = os.environ.copy()
        if os.name == "nt":
            environment["MSYS"] = "winsymlinks:nativestrict"
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


if __name__ == "__main__":
    unittest.main()
