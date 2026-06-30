# Building from source

Prerequisites: the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(it includes Dart). Per-OS build tools: Visual Studio with "Desktop development
with C++" (Windows), Xcode and CocoaPods (macOS), or
`clang cmake ninja-build pkg-config libgtk-3-dev libayatana-appindicator3-dev`
(Linux).

## One-command setup

From a fresh clone, a single idempotent script builds and installs the CLI and
the desktop app (with a Desktop/tray shortcut) and finishes by running
`quotabot doctor`:

```powershell
pwsh tools/setup.ps1          # Windows; add -CliOnly for just the CLI
```
```bash
bash tools/setup.sh           # macOS / Linux; add --cli-only for just the CLI
```

The CLI is installed to your per-user bin (`%LOCALAPPDATA%\quotabot\bin` on
Windows, `~/.local/bin` on macOS and Linux) and added to PATH. Re-run after a
`git pull` to update. The manual steps below are the same thing by hand.

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
  or MSIX.
- **macOS:** `bash tools/package-macos.sh` runs `flutter build macos --release`
  on a macOS host and verifies the `.app` bundle. Production distribution then
  needs Developer ID signing, notarization, stapling, and a DMG or ZIP.
- **Linux:** `bash tools/package-linux.sh` runs `flutter build linux --release`
  on a Linux host, verifies the executable bundle plus `.desktop` and icon
  assets, and can create a portable tarball. You can also repackage that bundle
  as an AppImage (`appimagetool`) or deb/rpm.
- **CLI release assets** for the one-command installers are built with
  `tools/package-cli.ps1` (Windows) or `tools/package-cli.sh` (macOS/Linux), each
  writing the asset plus a `.sha256` sidecar; upload both to the GitHub release.

The CI workflow runs the macOS and Linux desktop package scripts with
`--no-archive`, so every pull request verifies those platform bundles on their
native runners without publishing release artifacts.

## Icon and dev launcher

The application icon (`app/windows/runner/resources/app_icon.ico` on Windows,
`tools/quotabot.png` on Linux, sourced from `tools/quotabot-icon-1024.png`) is a
custom monochrome rune-style logo, distinct from the in-app pool gauge and "Quota"
wordmark. During development, `tools/local-setup.ps1` installs a `quotabot-gui`
command that launches from source with a deep clean and a visible console.

On Windows, OneDrive-synced folders can cause flaky builds (file locks on
generated directories); move the project outside OneDrive for reliable builds.
