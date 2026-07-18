import hashlib
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
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

    def test_posix_installers_stage_and_restore_payloads(self) -> None:
        release = (ROOT / "install.sh").read_text(encoding="utf-8")
        source = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")

        for script, destructive_line in (
            (release, 'rm -rf "$INSTALL_ROOT"'),
            (source, 'rm -rf "$install_root"'),
        ):
            with self.subTest(destructive_line=destructive_line):
                self.assertIn("replace_install_tree()", script)
                self.assertIn('swap_backup="$workspace/previous"', script)
                self.assertIn("acquire_swap_lock()", script)
                self.assertIn("set -o noclobber", script)
                self.assertIn("kill -0", script)
                self.assertIn('mv "$swap_backup" "$swap_target"', script)
                self.assertIn("the previous install was restored", script)
                self.assertNotIn(destructive_line, script)

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
                self.assertIn('".quotabot-bin-new-$transaction"', script)
                self.assertIn('".quotabot-bin-previous-$transaction"', script)
                self.assertIn("[IO.FileShare]::None", script)
                self.assertIn(
                    "Move-Item -LiteralPath $backupBin -Destination $binDst",
                    script,
                )
                self.assertIn("rollback was incomplete", script)
                self.assertNotIn(
                    "if (Test-Path -LiteralPath $binDst) { Remove-Item",
                    script,
                )

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
        posix_helper = (ROOT / "tools" / "package-pair.sh").read_text(
            encoding="utf-8"
        )
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
        self.assertIn('ditto "$built_app" "$staged_app"', script)
        self.assertIn('replace_install_tree "$staged_app"', script)
        self.assertIn("macOS installs the app\nunder `~/Applications`", readme)
        self.assertIn("macOS\ninstalls `~/Applications/quotabot.app`", building)

    def test_linux_source_setup_installs_a_stable_desktop_bundle(self) -> None:
        script = (ROOT / "tools" / "setup.sh").read_text(encoding="utf-8")
        building = (ROOT / "docs" / "BUILDING.md").read_text(encoding="utf-8")
        smoke = (ROOT / ".github" / "workflows" / "install-smoke.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            'installed_bundle="$HOME/.local/share/quotabot-desktop"', script
        )
        self.assertIn('replace_install_tree "$staged_bundle"', script)
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

    @unittest.skipIf(os.name == "nt", "POSIX installer behavior runs on POSIX")
    def test_posix_failed_activation_restores_previous_install(self) -> None:
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "bash is required for the POSIX installer test")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            fake_bin = root / "fake-bin"
            payload = root / "payload"
            archive = root / "quotabot-linux-x64.tar.gz"
            sidecar = root / "quotabot-linux-x64.tar.gz.sha256"
            install_root = home / ".local" / "share" / "quotabot"
            wrapper = home / ".local" / "bin" / "quotabot"

            (payload / "bin").mkdir(parents=True)
            (payload / "lib").mkdir()
            executable = payload / "bin" / "quotabot"
            executable.write_text("new", encoding="utf-8")
            executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
            (payload / "lib" / "sqlite3.test").write_text("new", encoding="utf-8")
            with tarfile.open(archive, mode="w:gz") as bundle:
                bundle.add(payload / "bin", arcname="bin")
                bundle.add(payload / "lib", arcname="lib")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            sidecar.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")

            (install_root / "bin").mkdir(parents=True)
            (install_root / "lib").mkdir()
            (install_root / "bin" / "quotabot").write_text("old", encoding="utf-8")
            (install_root / "lib" / "sqlite3.test").write_text("old", encoding="utf-8")
            install_lock = home / ".local" / "share" / ".quotabot-install.lock"
            install_lock.write_text("not-a-live-pid\n", encoding="utf-8")
            wrapper.parent.mkdir(parents=True)
            wrapper.write_text("old wrapper", encoding="utf-8")
            fake_bin.mkdir()

            (fake_bin / "curl").write_text(
                "#!/usr/bin/env sh\n"
                "url=''\n"
                "destination=''\n"
                'while [ "$#" -gt 0 ]; do\n'
                '  case "$1" in\n'
                "    -o) shift; destination=$1 ;;\n"
                "    http*) url=$1 ;;\n"
                "  esac\n"
                "  shift\n"
                "done\n"
                'case "$url" in\n'
                '  *.sha256) cp "$FAKE_SIDECAR" "$destination" ;;\n'
                '  *) cp "$FAKE_ARCHIVE" "$destination" ;;\n'
                "esac\n",
                encoding="utf-8",
            )
            (fake_bin / "uname").write_text(
                "#!/usr/bin/env sh\n"
                'case "$1" in\n'
                "  -s) echo Linux ;;\n"
                "  -m) echo x86_64 ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            real_mv = shutil.which("mv")
            self.assertIsNotNone(real_mv)
            (fake_bin / "mv").write_text(
                "#!/usr/bin/env sh\n"
                'case "$1" in\n'
                "  */new) exit 73 ;;\n"
                "esac\n"
                'exec "$REAL_MV" "$@"\n',
                encoding="utf-8",
            )
            for executable_path in fake_bin.iterdir():
                executable_path.chmod(executable_path.stat().st_mode | stat.S_IXUSR)

            environment = os.environ.copy()
            environment.update(
                {
                    "HOME": str(home),
                    "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                    "FAKE_ARCHIVE": str(archive),
                    "FAKE_SIDECAR": str(sidecar),
                    "REAL_MV": real_mv,
                    "QUOTABOT_REPO": "example/quotabot",
                }
            )
            completed = subprocess.run(
                [bash, str(ROOT / "install.sh")],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(
                (install_root / "bin" / "quotabot").read_text(encoding="utf-8"),
                "old",
            )
            self.assertEqual(
                (install_root / "lib" / "sqlite3.test").read_text(encoding="utf-8"),
                "old",
            )
            self.assertEqual(wrapper.read_text(encoding="utf-8"), "old wrapper")
            self.assertEqual(
                list((home / ".local" / "share").glob(".quotabot-install.*")),
                [],
            )
            self.assertFalse(install_lock.exists())


if __name__ == "__main__":
    unittest.main()
