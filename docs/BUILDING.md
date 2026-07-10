# Building from source

Prerequisites: the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(it includes Dart). Per-OS build tools: Visual Studio with "Desktop development
with C++" plus C++ ATL support for your installed MSVC toolset (Windows), Xcode
and CocoaPods (macOS), or
`clang cmake ninja-build pkg-config libgtk-3-dev libayatana-appindicator3-dev`
(Linux).

## One-command setup

From a fresh clone, a single idempotent script builds and installs the CLI and
the desktop app (with a Desktop shortcut) and finishes by running
`quotabot doctor`:

```powershell
pwsh tools/setup.ps1          # Windows; add -CliOnly for just the CLI
```
```bash
bash tools/setup.sh           # macOS / Linux; add --cli-only for just the CLI
```

The CLI is installed to your per-user bin (`%LOCALAPPDATA%\quotabot\bin` on
Windows, `~/.local/bin` on macOS and Linux) and added to PATH. Re-run after a
`git pull` to update. On Windows, if the source-built desktop app is already
running from the Release folder, setup restarts it after rebuilding so the tray
app is not left on old code. The manual steps below are the same thing by hand.

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
flutter build windows --release   # or macos / linux, on the target OS
```

Notes:

- Enable desktop targets once: `flutter config --enable-windows-desktop
  --enable-macos-desktop --enable-linux-desktop`.
- Build on the target OS; cross-compilation is not supported.
- **Windows:** the exe, data, and plugins land in
  `app/build/windows/x64/runner/Release/quotabot.exe`. `tools/package-windows.ps1`
  runs the build. Ship the Release folder as portable, or package with Inno Setup
  or MSIX. The desktop notification plugin uses Visual Studio ATL headers; if a
  build reports `atlbase.h` missing, modify Visual Studio Build Tools and add C++
  ATL support for your installed MSVC toolset.
- **macOS:** `bash tools/package-macos.sh` runs `flutter build macos --release`
  on a macOS host and verifies the `.app` bundle. Production distribution then
  needs Developer ID signing, notarization, stapling, and a DMG or ZIP.
- **Linux:** `bash tools/package-linux.sh` runs `flutter build linux --release`
  on a Linux host, verifies the executable bundle plus `.desktop` and icon
  assets, and can create a portable tarball. You can also repackage that bundle
  as an AppImage (`appimagetool`) or deb/rpm.
- **CLI release archives** for the one-command installers are built with
  `tools/package-cli.ps1` (Windows) or `tools/package-cli.sh` (macOS/Linux), each
  writing a `dart build cli` bundle archive plus a `.sha256` sidecar. The
  GitHub `Release` workflow runs those helpers on `v*` tags and uploads the
  installer assets automatically.

The CI workflow runs the Windows, macOS, and Linux desktop package scripts on
their native runners, using `--no-archive` for macOS and Linux, so every pull
request verifies those platform bundles without publishing release artifacts.
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
6. Push an annotated `vX.Y.Z` tag. Wait for both tag-triggered CI and every
   `Release` workflow job, including all four native build legs, to pass.
7. Confirm that the published release is neither draft nor prerelease and has
   exactly these archive and `.sha256` sidecar pairs:
   `quotabot-windows-x64.zip`, `quotabot-darwin-arm64.tar.gz`,
   `quotabot-linux-x64.tar.gz`, and `quotabot-linux-arm64.tar.gz`.
8. Download every archive, compare it with its SHA-256 sidecar, and verify its
   repository provenance with `gh attestation verify <archive> --repo
   blisspixel/quotabot`. That basic command does not constrain the signer or tag;
   the install-smoke workflow adds signer-workflow, source-ref, source-digest,
   and self-hosted-runner restrictions for the release gate.
   The release workflow creates the attestation before uploading each pair.
9. Install and smoke-test the packaged CLI on clean Windows, macOS, and Linux
   hosts before promoting a stable release candidate.
10. Confirm GitHub security signals are clear: CI, CodeQL, secret scanning,
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
