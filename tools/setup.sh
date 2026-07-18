#!/usr/bin/env bash
# One-command setup for quotabot from source on macOS and Linux.
#
# Builds and installs the quotabot CLI, and (by default) the desktop app, then
# runs `quotabot doctor`. Idempotent: safe to re-run after a `git pull`.
# No quotabot account or telemetry is used. `doctor` reads quota metadata only:
# no prompts, code, inference requests, or usage-token-spending calls.
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
install_root="$HOME/.local/share/quotabot"

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
asset="$root/release/quotabot-${os}-${arch}.tar.gz"
[ -f "$asset" ] || { echo "CLI build did not produce $asset" >&2; exit 1; }

install_dir="$HOME/.local/bin"
step "Installing the CLI to $install_root"
mkdir -p "$install_dir"
tmpdir="$(mktemp -d)"
swap_workspace=""
swap_target=""
swap_backup=""
swap_old_moved=0
swap_committed=0
swap_lock=""
swap_lock_owner=""
wrapper_tmp=""
release_swap_lock() {
  if [[ -n "$swap_lock" && -f "$swap_lock" && \
        "$(cat "$swap_lock" 2>/dev/null)" == "$swap_lock_owner" ]]; then
    rm -f "$swap_lock"
  fi
  swap_lock=""
  swap_lock_owner=""
}
acquire_swap_lock() {
  local lock_path="$1"
  local existing_owner stale_lock

  swap_lock="$lock_path"
  swap_lock_owner="${BASHPID:-$$}"
  if (set -o noclobber; printf '%s\n' "$swap_lock_owner" > "$swap_lock") 2>/dev/null; then
    return 0
  fi

  existing_owner="$(cat "$swap_lock" 2>/dev/null || true)"
  case "$existing_owner" in
    ''|*[!0-9]*) owner_is_live=0 ;;
    *)
      if kill -0 "$existing_owner" 2>/dev/null; then
        owner_is_live=1
      else
        owner_is_live=0
      fi
      ;;
  esac
  if [[ "$owner_is_live" -eq 1 ]]; then
    echo 'Another quotabot install is already activating a bundle. Re-run after it finishes.' >&2
    swap_lock=""
    swap_lock_owner=""
    return 1
  fi

  stale_lock="$swap_lock.stale.$swap_lock_owner"
  if ! mv "$swap_lock" "$stale_lock" 2>/dev/null; then
    echo 'Could not recover the stale quotabot install lock.' >&2
    swap_lock=""
    swap_lock_owner=""
    return 1
  fi
  rm -f "$stale_lock"
  if ! (set -o noclobber; printf '%s\n' "$swap_lock_owner" > "$swap_lock") 2>/dev/null; then
    echo 'Another quotabot install started activating a bundle.' >&2
    swap_lock=""
    swap_lock_owner=""
    return 1
  fi
}
cleanup_setup() {
  status=$?
  set +e
  preserve_swap=0
  if [[ "$swap_old_moved" -eq 1 && "$swap_committed" -eq 0 && \
        -e "$swap_backup" && ! -e "$swap_target" ]]; then
    if ! mv "$swap_backup" "$swap_target"; then
      echo "Install rollback failed. Previous bundle remains at $swap_backup" >&2
      preserve_swap=1
    fi
  fi
  if [[ -n "$swap_workspace" && "$preserve_swap" -eq 0 ]]; then
    rm -rf "$swap_workspace"
  fi
  release_swap_lock
  if [[ -n "$wrapper_tmp" ]]; then
    rm -f "$wrapper_tmp"
  fi
  rm -rf "$tmpdir"
  return "$status"
}
trap cleanup_setup EXIT

replace_install_tree() {
  local staged="$1"
  local target="$2"
  local workspace="$3"

  swap_workspace="$workspace"
  swap_target="$target"
  swap_backup="$workspace/previous"
  swap_old_moved=0
  swap_committed=0
  swap_lock="$(dirname "$target")/.quotabot-install.lock"

  if ! acquire_swap_lock "$swap_lock"; then
    return 1
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    mv "$target" "$swap_backup"
    swap_old_moved=1
  fi
  if ! mv "$staged" "$target"; then
    if [[ "$swap_old_moved" -eq 1 && ! -e "$target" ]]; then
      mv "$swap_backup" "$target"
      swap_old_moved=0
    fi
    echo "Could not activate the new quotabot bundle; the previous install was restored." >&2
    release_swap_lock
    return 1
  fi

  swap_committed=1
  if [[ "$swap_old_moved" -eq 1 ]]; then
    rm -rf "$swap_backup"
  fi
  rmdir "$workspace"
  release_swap_lock
  swap_workspace=""
  swap_target=""
  swap_backup=""
  swap_old_moved=0
  swap_committed=0
  swap_lock=""
  swap_lock_owner=""
}

tar -xzf "$asset" -C "$tmpdir"
[ -x "$tmpdir/bin/quotabot" ] || { echo "CLI archive did not contain executable bin/quotabot" >&2; exit 1; }
[ -d "$tmpdir/lib" ] || { echo "CLI archive did not contain lib/" >&2; exit 1; }

install_parent="$(dirname "$install_root")"
mkdir -p "$install_parent"
swap_workspace="$(mktemp -d "$install_parent/.quotabot-install.XXXXXX")"
staged_root="$swap_workspace/new"
mkdir -p "$staged_root"
cp -R "$tmpdir/bin" "$tmpdir/lib" "$staged_root/"
[ -x "$staged_root/bin/quotabot" ] || { echo "Could not stage bin/quotabot" >&2; exit 1; }
[ -d "$staged_root/lib" ] || { echo "Could not stage lib/" >&2; exit 1; }
replace_install_tree "$staged_root" "$install_root" "$swap_workspace"

wrapper_tmp="$(mktemp "$install_dir/.quotabot.XXXXXX")"
cat > "$wrapper_tmp" <<EOF
#!/usr/bin/env bash
exec "$install_root/bin/quotabot" "\$@"
EOF
chmod +x "$wrapper_tmp"
mv -f "$wrapper_tmp" "$install_dir/quotabot"
wrapper_tmp=""
ok 'Installed quotabot'
case ":$PATH:" in
  *":$install_dir:"*) ok 'Install dir already on PATH' ;;
  *) warn "Add $install_dir to your PATH (e.g. in ~/.bashrc or ~/.zshrc): export PATH=\"$install_dir:\$PATH\"" ;;
esac

if [ "$cli_only" -eq 0 ]; then
  step 'Building the desktop app (this takes a few minutes)'
  if [ "$os" = darwin ]; then
    (cd "$app" && flutter build macos --release)
    built_app="$app/build/macos/Build/Products/Release/quotabot.app"
    [ -x "$built_app/Contents/MacOS/quotabot" ] || {
      echo "Desktop build did not produce $built_app" >&2
      exit 1
    }
    applications="$HOME/Applications"
    installed_app="$applications/quotabot.app"
    mkdir -p "$applications"
    swap_workspace="$(mktemp -d "$applications/.quotabot-app-install.XXXXXX")"
    staged_app="$swap_workspace/quotabot.app"
    ditto "$built_app" "$staged_app"
    [ -x "$staged_app/Contents/MacOS/quotabot" ] || {
      echo "Could not stage the macOS app bundle" >&2
      exit 1
    }
    replace_install_tree "$staged_app" "$installed_app" "$swap_workspace"
    ok "Installed the desktop app to $installed_app"
  else
    (cd "$app" && flutter build linux --release)
    bundle="$app/build/linux/$arch/release/bundle"
    [ -x "$bundle/quotabot" ] || {
      echo "Desktop build did not produce $bundle/quotabot" >&2
      exit 1
    }
    installed_bundle="$HOME/.local/share/quotabot-desktop"
    applications="$HOME/.local/share/applications"
    mkdir -p "$applications"
    swap_workspace="$(mktemp -d "$HOME/.local/share/.quotabot-desktop-install.XXXXXX")"
    staged_bundle="$swap_workspace/quotabot-desktop"
    cp -R "$bundle" "$staged_bundle"
    [ -x "$staged_bundle/quotabot" ] || {
      echo 'Could not stage the Linux desktop bundle' >&2
      exit 1
    }
    replace_install_tree "$staged_bundle" "$installed_bundle" "$swap_workspace"
    desktop="$HOME/.local/share/applications/quotabot.desktop"
    bash "$script_dir/write-desktop-entry.sh" \
      "$script_dir/quotabot.desktop" "$installed_bundle/quotabot" "$desktop"
    ok "Installed the desktop app to $installed_bundle"
    ok "Installed an application-menu entry: $desktop"
  fi
fi

step 'Verifying with quotabot doctor'
"$install_dir/quotabot" doctor || warn 'doctor reported an issue (expected if no provider tools have run yet).'

echo
printf '\033[32mquotabot is set up.\033[0m\n'
echo "  CLI:   quotabot --help"
[ "$cli_only" -eq 0 ] && echo "  App:   launch quotabot from your applications menu"
echo "  Route: quotabot suggest   (which subscription to use next)"
