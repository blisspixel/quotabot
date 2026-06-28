#!/usr/bin/env bash
# One-command setup for quotabot from source on macOS and Linux.
#
# Builds and installs the quotabot CLI, and (by default) the desktop app, then
# runs `quotabot doctor`. Idempotent: safe to re-run after a `git pull`.
# Everything stays local; no telemetry, no account.
#
# An AI agent can run this unattended:  bash tools/setup.sh --cli-only
#
# Usage:
#   bash tools/setup.sh             # CLI + desktop app
#   bash tools/setup.sh --cli-only  # CLI only (no Flutter desktop build)

set -euo pipefail

cli_only=0
for arg in "$@"; do
  case "$arg" in
    --cli-only) cli_only=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
collector="$root/collector"
app="$root/app"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok() { printf '\033[32m    %s\033[0m\n' "$1"; }
warn() { printf '\033[33m    %s\033[0m\n' "$1"; }

step 'Locating the Dart toolchain'
if ! command -v dart >/dev/null 2>&1; then
  echo "Dart/Flutter not found. Install Flutter (https://docs.flutter.dev/get-started/install) and re-run." >&2
  exit 1
fi
ok "$(dart --version 2>&1 | head -n1)"

step 'Building the quotabot CLI'
(cd "$collector" && dart pub get >/dev/null && bash "$script_dir/package-cli.sh")

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in darwin*) os=darwin ;; linux*) os=linux ;; esac
arch="$(uname -m)"
case "$arch" in x86_64 | amd64) arch=x64 ;; arm64 | aarch64) arch=arm64 ;; esac
asset="$root/release/quotabot-${os}-${arch}"
[ -f "$asset" ] || { echo "CLI build did not produce $asset" >&2; exit 1; }

install_dir="$HOME/.local/bin"
step "Installing the CLI to $install_dir"
mkdir -p "$install_dir"
install -m 0755 "$asset" "$install_dir/quotabot"
ok 'Installed quotabot'
case ":$PATH:" in
  *":$install_dir:"*) ok 'Install dir already on PATH' ;;
  *) warn "Add $install_dir to your PATH (e.g. in ~/.bashrc or ~/.zshrc): export PATH=\"$install_dir:\$PATH\"" ;;
esac

if [ "$cli_only" -eq 0 ]; then
  step 'Building the desktop app (this takes a few minutes)'
  if [ "$os" = darwin ]; then
    (cd "$app" && flutter build macos --release)
    ok "Built app/build/macos/Build/Products/Release/quotabot.app (drag it to /Applications)"
  else
    (cd "$app" && flutter build linux --release)
    bundle="$app/build/linux/$arch/release/bundle"
    desktop="$HOME/.local/share/applications/quotabot.desktop"
    mkdir -p "$(dirname "$desktop")"
    sed "s#Exec=quotabot#Exec=$bundle/quotabot#" "$script_dir/quotabot.desktop" > "$desktop"
    ok "Installed a desktop entry: $desktop"
  fi
fi

step 'Verifying with quotabot doctor'
"$install_dir/quotabot" doctor || warn 'doctor reported an issue (expected if no provider tools have run yet).'

echo
printf '\033[32mquotabot is set up.\033[0m\n'
echo "  CLI:   quotabot --help"
[ "$cli_only" -eq 0 ] && echo "  App:   launch quotabot from your applications menu or the built bundle"
echo "  Route: quotabot suggest   (which subscription to use next)"
