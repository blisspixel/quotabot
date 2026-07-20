# Building from source

Prerequisites: Flutter 3.44.6 with Dart 3.12.2, the exact toolchain pinned in CI
and release builds. Install it from the
[Flutter SDK archive](https://docs.flutter.dev/install/archive); Flutter includes
Dart. Per-OS build tools: Visual Studio with "Desktop development
with C++" plus C++ ATL support for your installed MSVC toolset (Windows), Xcode
and CocoaPods (macOS), or
`clang cmake ninja-build pkg-config libgtk-3-dev libayatana-appindicator3-dev`
(Linux).

## One-command setup

From a fresh clone, a single idempotent script builds and installs the CLI and
the desktop app, then finishes by running `quotabot doctor`:

```powershell
pwsh tools/setup.ps1          # Windows; add -CliOnly for just the CLI
```
```bash
bash tools/setup.sh           # macOS / Linux; add --cli-only for just the CLI
```

The CLI command is exposed through your per-user bin
(`%LOCALAPPDATA%\quotabot\bin` on Windows, `~/.local/bin` on macOS and Linux).
On macOS and Linux, that command shim launches the stable complete payload at
`~/.local/share/quotabot`. Windows setup adds its bin directory to the user
PATH. On macOS and Linux, setup reports the exact shell-profile change when
`~/.local/bin` is not already on PATH. Windows creates a Desktop
shortcut to `%LOCALAPPDATA%\quotabot\desktop`, Linux installs the app under
`~/.local/share/quotabot-desktop` with an application-menu entry, and macOS
installs `~/Applications/quotabot.app`. These launchers remain valid if the
source checkout moves or is removed. Re-run after a `git pull` to update. On
Windows, setup restarts a running installed desktop app after activation so the
tray app is not left on old code. The manual steps below are the same thing by
hand.

Setup stages each CLI or desktop payload as one complete versioned generation
before switching its stable entry path. On macOS and Linux, the active target is
a relative symlink and its private sibling version store retains the immediate
predecessor for recovery. Uninstall must remove both paths; the exact commands
are in [SETUP.md](SETUP.md#uninstall-the-release-cli-but-preserve-data).
On macOS and Linux, full source setup stages and validates both payload
generations before activating either stable target. If either payload activation
fails, setup restores both prior stable targets before returning an error. The
CLI-only path remains one versioned transaction.

## Run from source

```bash
# CLI
cd collector
dart run bin/collect.dart doctor
dart run bin/collect.dart login grok

# Desktop widget
cd app
flutter run -d windows   # or macos / linux
```

## Build a release binary

```bash
cd app
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub   # or macos / linux, on the target OS
```

Notes:

- Enable desktop targets once: `flutter config --enable-windows-desktop
  --enable-macos-desktop --enable-linux-desktop`.
- Build on the target OS; cross-compilation is not supported.
- **Windows:** the exe, data, and plugins land in
  `app/build/windows/x64/runner/Release/quotabot.exe`. `tools/package-windows.ps1`
  runs the build and writes `release/quotabot-windows-x64-desktop.zip` plus its
  checksum sidecar. The packager refuses non-x64 hosts so it cannot mislabel a
  different native build as that x64 asset. Add `-NoArchive` for a build-only
  check. The desktop notification plugin uses Visual Studio ATL headers; if a
  build reports `atlbase.h` missing, modify Visual Studio Build Tools and add C++
  ATL support for your installed MSVC toolset.
- **macOS:** `bash tools/package-macos.sh` verifies the committed lockfile, then
  runs `flutter build macos --release --no-pub`
  on a macOS host, verifies the `.app` bundle, and writes a portable desktop ZIP
  plus its checksum sidecar. Production distribution still needs Developer ID
  signing, notarization, and stapling.
- **Linux:** `bash tools/package-linux.sh` verifies the committed lockfile, then
  runs `flutter build linux --release --no-pub`
  on a Linux host, verifies the executable bundle plus `.desktop` and icon
  assets, and creates a portable tarball plus its checksum sidecar. You can also
  repackage that bundle as an AppImage (`appimagetool`) or deb/rpm.
- **CLI release archives** for the one-command installers are built with
  `tools/package-cli.ps1` (Windows) or `tools/package-cli.sh` (macOS/Linux), each
  writing a `dart build cli` bundle archive plus a `.sha256` sidecar. The
  GitHub `Release` workflow runs the CLI and desktop helpers on `v*` tags,
  validates every CLI and desktop archive, and attests each exact archive path.
  Clean native runners then redownload all four draft CLI archives, reverify
  checksum and provenance, and require the packaged version and demo-mode
  `doctor --json` to run. Three more native runners reverify the desktop
  archives and exercise their portable lifecycle before the exact-asset audit
  allows publication. The separate `Install smoke` workflow tests the published
  one-line installer, a versioned upgrade, persistent data, and source setup.

The CI workflow runs the Windows, macOS, and Linux desktop package scripts on
their native runners and validates each resulting archive plus checksum, so
every change exercises the same portable bundle shape without publishing release
assets. The build-only `-NoArchive` and `--no-archive` flags remain available for
local iteration.
It then launches the packaged Windows and Linux apps and requires native window
setup plus every supported tray-registration call to complete. Windows verifies
the native `Shell_NotifyIconGetRect` result and rectangle independently of the
tray plugin. The app exposes that integration-only signal when
`QUOTABOT_DESKTOP_READINESS_FILE` names an output path; normal application runs
do not write a readiness file.

GitHub-hosted macOS runners build the app, but direct and LaunchServices bundle
launches did not publish an app-authored window or status-item readiness
transition. That environment therefore is not used as evidence of interactive
macOS readiness. On an interactive macOS host, run the same bundle-aware
readiness harness after packaging:

```bash
python tools/desktop_readiness_smoke.py \
  --executable app/build/macos/Build/Products/Release/quotabot.app/Contents/MacOS/quotabot
```

The harness launches the `.app` through LaunchServices, not by invoking its
inner executable directly. Automated startup gates do not replace the release
candidate's interactive launcher, visible-tray, close-to-tray, and reopen check
on clean desktop sessions.

## Release dry run

Before cutting a public tag, verify the release exactly the way an installer and
maintainer will consume it:

1. Align the collector package, CLI and MCP constants, desktop package and
   lockfile, changelog release heading, and roadmap current-version line. Run
   `python tools/check_release_version.py --tag vX.Y.Z`; it must confirm the
   intended tag and one consistent version. The release workflow enforces the
   same exact tag-to-source check before creating a draft.
2. Build the current platform's archive with `tools\package-cli.ps1` on Windows
   or `tools/package-cli.sh` on macOS/Linux.
3. Confirm the `.sha256` sidecar contains a 64 character SHA-256 hash and the
   archive filename, then compare it with the archive's actual hash.
4. Expand the archive in an isolated temporary directory and run the packaged
   CLI (`bin\quotabot.exe` on Windows or `bin/quotabot` on macOS/Linux) with
   `--version` plus demo-mode `doctor --json` under an isolated config
   directory.
5. Commit the release metadata on `main`, push it, and wait for hosted Windows,
   macOS, and Ubuntu CI plus CodeQL and secret scanning to pass before tagging.
6. Before tagging, repeat the package and execution smoke on each claimed native
   host and complete the interactive launcher, tray, and accessibility checks
   that hosted automation cannot prove. Record an unavailable cell explicitly
   rather than treating a shared-code test as native evidence.
7. Verify the official repository still has the active `v*` tag ruleset that
   blocks updates and deletion, plus GitHub release immutability. Immutability
   applies only to releases published after the setting was enabled on July 18,
   2026; it does not retroactively change v0.9.2 or earlier releases.
8. Push an annotated `vX.Y.Z` tag. Wait for every `Release` workflow job,
   including its reusable CI quality gate, four CLI builds, four clean CLI
   execution legs, three desktop builds, and three clean desktop
   archive-verification legs, to pass.
9. Confirm that the published stable release is neither draft nor prerelease,
   is marked immutable, and has
   these CLI archive and `.sha256` sidecar pairs:
   `quotabot-windows-x64.zip`, `quotabot-darwin-arm64.tar.gz`,
   `quotabot-linux-x64.tar.gz`, and `quotabot-linux-arm64.tar.gz`.
   Confirm the three desktop pairs are also present:
   `quotabot-windows-x64-desktop.zip`,
   `quotabot-darwin-arm64-desktop.zip`, and
   `quotabot-linux-x64-desktop.tar.gz`.
10. Download every archive, compare it with its SHA-256 sidecar, and verify its
   repository provenance with `gh attestation verify <archive> --repo
   blisspixel/quotabot`. That basic command does not constrain the signer or tag;
   the release and install-smoke workflows add signer-workflow, source-ref,
   source-digest, and self-hosted-runner restrictions.
   The release workflow creates the attestation before uploading each pair.
11. After publication, dispatch `Install smoke` immediately and require its
    clean install, prior-version upgrade, persistent-state, and source-setup
    matrix to pass on Windows, macOS, and Linux.
12. Confirm GitHub security signals are clear: CI, CodeQL, secret scanning,
    Dependabot alerts, and the dependency-review PR gate.

The `Install smoke` workflow automates the post-release clean-host portion of
this checklist on native Windows, macOS, and Linux runners. It resolves the
latest published release and prior 0.x release, pins checkout to the release-tag
commit, verifies checksums and provenance, exercises a clean one-line install,
then tests the prior-release upgrade plus CLI-only and full source setup with a
persistent-state sentinel. Its final checks cover the packaged CLI, demo doctor
schema, Windows shortcut target, macOS app bundle, and Linux desktop entry. It
runs weekly and can be dispatched with explicit tags for repeatable published
release regression evidence. A pre-publication candidate dry run and interactive
tray-readiness check remain separate release-candidate requirements.

## Icon and dev launcher

The application icon (`app/windows/runner/resources/app_icon.ico` on Windows,
`tools/quotabot.png` on Linux, sourced from `tools/quotabot-icon-1024.png`) is a
custom monochrome rune-style logo, distinct from the in-app pool gauge and "Quota"
wordmark. During development, `tools/local-setup.ps1` installs a `quotabot-gui`
command that launches from source with a deep clean and a visible console.

On Windows, OneDrive-synced folders can cause flaky builds (file locks on
generated directories); move the project outside OneDrive for reliable builds.
