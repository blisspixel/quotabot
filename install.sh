#!/usr/bin/env bash
#
# One-command installer for quotabot CLI (macOS and Linux)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/owner/quotabot/main/install.sh | QUOTABOT_REPO=owner/quotabot bash
#   curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | QUOTABOT_VERSION=v0.9.0 bash
#

set -euo pipefail

REPO="${QUOTABOT_REPO:-blisspixel/quotabot}"
VERSION="${QUOTABOT_VERSION:-latest}"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_ROOT="${HOME}/.local/share/quotabot"
BINARY_NAME="quotabot"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid QUOTABOT_REPO value. Expected owner/repo." >&2
  exit 1
fi
if [[ "$VERSION" != "latest" && ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid QUOTABOT_VERSION value. Expected vMAJOR.MINOR.PATCH." >&2
  exit 1
fi

echo "Installing quotabot CLI..."

# Create destination
mkdir -p "$INSTALL_DIR"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  darwin*)  OS="darwin" ;;
  linux*)   OS="linux" ;;
  *)        echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64 | amd64) ARCH="x64" ;;
  arm64 | aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Intel macOS has no prebuilt binary (GitHub retired the Intel runner and Intel
# Macs are past end of life). Point those users at the from-source build instead
# of failing on a 404.
if [[ "$OS" == "darwin" && "$ARCH" == "x64" ]]; then
  echo "No prebuilt CLI for Intel macOS. Build from source instead:" >&2
  echo "  git clone https://github.com/${REPO}.git" >&2
  echo "  cd quotabot && bash tools/setup.sh --cli-only" >&2
  exit 1
fi

ASSET="quotabot-${OS}-${ARCH}.tar.gz"
if [[ "$VERSION" == "latest" ]]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi

echo "Downloading ${ASSET} from ${VERSION}..."

tmpfile=$(mktemp)
checksum_file=$(mktemp)
extract_dir=$(mktemp -d)
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
cleanup() {
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
  rm -f "$tmpfile" "$checksum_file"
  rm -rf "$extract_dir"
  return "$status"
}
trap cleanup EXIT

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

curl -fsSL "$URL" -o "$tmpfile"
curl -fsSL "${URL}.sha256" -o "$checksum_file"
expected=$(awk 'NR==1 {print tolower($1)}' "$checksum_file")
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid checksum file for ${ASSET}" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmpfile" | awk '{print tolower($1)}')
else
  actual=$(shasum -a 256 "$tmpfile" | awk '{print tolower($1)}')
fi
if [[ "$actual" != "$expected" ]]; then
  echo "Checksum mismatch for ${ASSET}" >&2
  exit 1
fi
tar -xzf "$tmpfile" -C "$extract_dir"
if [[ ! -x "$extract_dir/bin/quotabot" ]]; then
  echo "Downloaded archive did not contain executable bin/quotabot" >&2
  exit 1
fi
if [[ ! -d "$extract_dir/lib" ]]; then
  echo "Downloaded archive did not contain lib/" >&2
  exit 1
fi

# Stage the complete bundle beside the live install. Renames within one parent
# are atomic, and the EXIT trap restores the previous tree if activation fails.
install_parent=$(dirname "$INSTALL_ROOT")
mkdir -p "$install_parent"
swap_workspace=$(mktemp -d "$install_parent/.quotabot-install.XXXXXX")
staged_root="$swap_workspace/new"
mkdir -p "$staged_root"
cp -R "$extract_dir/bin" "$extract_dir/lib" "$staged_root/"
if [[ ! -x "$staged_root/bin/quotabot" || ! -d "$staged_root/lib" ]]; then
  echo "Could not stage the downloaded quotabot bundle" >&2
  exit 1
fi
replace_install_tree "$staged_root" "$INSTALL_ROOT" "$swap_workspace"

# Keep the PATH shim valid until its complete replacement is ready.
wrapper_tmp=$(mktemp "$INSTALL_DIR/.quotabot.XXXXXX")
cat > "$wrapper_tmp" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_ROOT/bin/quotabot" "\$@"
EOF
chmod +x "$wrapper_tmp"
mv -f "$wrapper_tmp" "$INSTALL_DIR/$BINARY_NAME"
wrapper_tmp=""

# PATH check
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "NOTE: $INSTALL_DIR is not in your PATH."
  echo "Add this line to your shell profile (~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish, etc.):"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
  echo "Then run:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "quotabot installed to $INSTALL_ROOT"
echo ""
echo "Next steps:"
echo "  quotabot doctor"
echo "  quotabot login grok"
echo "  quotabot login antigravity  # optional, keeps Antigravity live"
echo ""
echo "Re-run this script anytime to update."
