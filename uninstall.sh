#!/usr/bin/env bash
# Uninstalls the quotabot CLI and desktop app on macOS and Linux.
# Removes the CLI and desktop app installations, and removes desktop shortcuts.
# Does not delete metadata, cache, or logs unless the --purge switch is provided.

set -euo pipefail

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    -h | --help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok() { printf '\033[32m    %s\033[0m\n' "$1"; }

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  darwin*) os=darwin ;;
  linux*) os=linux ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac

step 'Removing CLI installations'
if [ -L "$HOME/.local/bin/quotabot" ] || [ -f "$HOME/.local/bin/quotabot" ]; then
  rm -f "$HOME/.local/bin/quotabot"
  ok 'Removed ~/.local/bin/quotabot'
fi

if [ -d "$HOME/.local/share/quotabot" ]; then
  rm -rf "$HOME/.local/share/quotabot"
  ok 'Removed ~/.local/share/quotabot'
fi

if [ -d "$HOME/.local/share/.quotabot-versions" ]; then
  rm -rf "$HOME/.local/share/.quotabot-versions"
  ok 'Removed ~/.local/share/.quotabot-versions'
fi

step 'Removing desktop installations'
# Stop process if running
if pgrep -x "quotabot" > /dev/null; then
  ok 'Stopping running quotabot processes...'
  pkill -x "quotabot" || true
  sleep 1
fi

if [ "$os" = "darwin" ]; then
  if [ -d "$HOME/Applications/quotabot.app" ]; then
    rm -rf "$HOME/Applications/quotabot.app"
    ok 'Removed ~/Applications/quotabot.app'
  fi
elif [ "$os" = "linux" ]; then
  if [ -d "$HOME/.local/share/quotabot-desktop" ]; then
    rm -rf "$HOME/.local/share/quotabot-desktop"
    ok 'Removed ~/.local/share/quotabot-desktop'
  fi
  if [ -f "$HOME/.local/share/applications/quotabot.desktop" ]; then
    rm -f "$HOME/.local/share/applications/quotabot.desktop"
    ok 'Removed desktop menu entry'
  fi
fi

if [ "$purge" -eq 1 ]; then
  step 'Purging metadata, cache, and logs'
  if [ -d "$HOME/.cache/quotabot" ]; then
    rm -rf "$HOME/.cache/quotabot"
  fi
  # Quotabot data dir varies by OS
  if [ "$os" = "darwin" ] && [ -d "$HOME/Library/Application Support/quotabot" ]; then
    rm -rf "$HOME/Library/Application Support/quotabot"
  elif [ "$os" = "linux" ] && [ -d "$HOME/.config/quotabot" ]; then
    rm -rf "$HOME/.config/quotabot"
  fi
  ok 'Purged quotabot data directory'
fi

printf '\n\033[32mquotabot has been successfully uninstalled.\033[0m\n'
