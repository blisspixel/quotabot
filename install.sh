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
transaction_versions_root=""
transaction_staging=""
transaction_generation=""
transaction_link=""
transaction_target=""
transaction_legacy_backup=""
transaction_legacy_moved=0
transaction_committed=0
transaction_lock=""
transaction_lock_owner=""
wrapper_tmp=""
release_install_lock() {
  if [[ -n "$transaction_lock" && -f "$transaction_lock" && \
        "$(cat "$transaction_lock" 2>/dev/null)" == "$transaction_lock_owner" ]]; then
    rm -f "$transaction_lock"
  fi
  transaction_lock=""
  transaction_lock_owner=""
}
acquire_install_lock() {
  local lock_path="$1"
  local existing_owner owner_is_live stale_lock

  transaction_lock="$lock_path"
  transaction_lock_owner="${BASHPID:-$$}"
  if (set -o noclobber; printf '%s\n' "$transaction_lock_owner" > "$transaction_lock") 2>/dev/null; then
    return 0
  fi

  existing_owner="$(cat "$transaction_lock" 2>/dev/null || true)"
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
    transaction_lock=""
    transaction_lock_owner=""
    return 1
  fi

  stale_lock="$transaction_lock.stale.$transaction_lock_owner"
  if ! mv "$transaction_lock" "$stale_lock" 2>/dev/null; then
    echo 'Could not recover the stale quotabot install lock.' >&2
    transaction_lock=""
    transaction_lock_owner=""
    return 1
  fi
  rm -f "$stale_lock"
  if ! (set -o noclobber; printf '%s\n' "$transaction_lock_owner" > "$transaction_lock") 2>/dev/null; then
    echo 'Another quotabot install started activating a bundle.' >&2
    transaction_lock=""
    transaction_lock_owner=""
    return 1
  fi
}
safe_remove_versioned_tree() {
  local candidate="$1"
  local candidate_name
  case "$candidate" in
    "$transaction_versions_root"/*)
      candidate_name="${candidate#"$transaction_versions_root"/}"
      ;;
    *)
      echo "Refusing to remove a path outside the quotabot versions directory: $candidate" >&2
      return 1
      ;;
  esac
  if [[ "$candidate_name" == */* || \
        ! "$candidate_name" =~ ^(\.staging|generation|legacy)-[0-9]{14}-[0-9]+$ ]]; then
    echo "Refusing to remove an unrecognized quotabot generation: $candidate" >&2
    return 1
  fi
  rm -rf -- "$candidate"
}
reset_transaction_state() {
  transaction_versions_root=""
  transaction_staging=""
  transaction_generation=""
  transaction_link=""
  transaction_target=""
  transaction_legacy_backup=""
  transaction_legacy_moved=0
  transaction_committed=0
  transaction_lock=""
  transaction_lock_owner=""
}
cleanup() {
  status=$?
  set +e
  preserve_generation=0
  if [[ "$transaction_legacy_moved" -eq 1 && "$transaction_committed" -eq 0 && \
        -d "$transaction_legacy_backup" && \
        ! -e "$transaction_target" && ! -L "$transaction_target" ]]; then
    if ! mv "$transaction_legacy_backup" "$transaction_target"; then
      echo "Install rollback failed. Previous bundle remains at $transaction_legacy_backup" >&2
      preserve_generation=1
    fi
  fi
  if [[ -n "$transaction_link" ]]; then
    rm -f "$transaction_link"
  fi
  if [[ -n "$transaction_staging" && "$preserve_generation" -eq 0 ]]; then
    safe_remove_versioned_tree "$transaction_staging"
  fi
  if [[ -n "$transaction_generation" && "$transaction_committed" -eq 0 && \
        "$preserve_generation" -eq 0 ]]; then
    safe_remove_versioned_tree "$transaction_generation"
  fi
  release_install_lock
  if [[ -n "$wrapper_tmp" ]]; then
    rm -f "$wrapper_tmp"
  fi
  rm -f "$tmpfile" "$checksum_file"
  rm -rf "$extract_dir"
  return "$status"
}
trap cleanup EXIT

activate_install_link() {
  local candidate="$1"
  local target="$2"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    mv "$candidate" "$target"
  elif [[ "$OS" == "darwin" ]]; then
    # BSD mv needs -h to replace a symlink to a directory itself.
    mv -fh "$candidate" "$target"
  else
    # GNU and BusyBox mv use -T to treat the destination as a path, not a dir.
    mv -fT "$candidate" "$target"
  fi
}
validated_previous_generation() {
  local stable_target="$1"
  local versions_name="$2"
  local versions_root="$3"
  local active_relative active_name candidate resolved_candidate

  active_relative="$(readlink "$stable_target")"
  case "$active_relative" in
    "$versions_name"/*) active_name="${active_relative#"$versions_name"/}" ;;
    *)
      echo "Refusing to replace an unrecognized install symlink: $stable_target" >&2
      return 1
      ;;
  esac
  if [[ "$active_name" == */* || \
        ! "$active_name" =~ ^(generation|legacy)-[0-9]{14}-[0-9]+$ ]]; then
    echo "Refusing to replace an unrecognized install symlink: $stable_target" >&2
    return 1
  fi
  candidate="$versions_root/$active_name"
  if [[ ! -d "$candidate" || -L "$candidate" ]]; then
    echo "Refusing to replace an invalid install generation: $candidate" >&2
    return 1
  fi
  resolved_candidate="$(cd "$candidate" && pwd -P)"
  if [[ "$resolved_candidate" != "$candidate" ]]; then
    echo "Refusing to use an install generation outside its versions directory: $candidate" >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}
install_versioned_tree() {
  local source="$1"
  local requested_target="$2"
  local payload_kind="$3"
  local target_parent target_name versions_name generation_id previous_generation
  local entry active_path

  target_parent="$(dirname "$requested_target")"
  target_name="$(basename "$requested_target")"
  case "$target_name" in
    '' | '.' | '..' | *[!A-Za-z0-9._-]*)
      echo "Invalid install target name: $target_name" >&2
      return 1
      ;;
  esac
  mkdir -p "$target_parent"
  target_parent="$(cd "$target_parent" && pwd -P)"
  transaction_target="$target_parent/$target_name"
  versions_name=".${target_name}-versions"
  transaction_versions_root="$target_parent/$versions_name"
  if [[ -L "$transaction_versions_root" ]]; then
    echo "Refusing to use a symlink as the quotabot versions directory: $transaction_versions_root" >&2
    return 1
  fi
  mkdir -p "$transaction_versions_root"
  transaction_versions_root="$(cd "$transaction_versions_root" && pwd -P)"
  case "$transaction_versions_root" in
    "$target_parent"/*) ;;
    *)
      echo 'The quotabot versions directory resolved outside its install parent.' >&2
      return 1
      ;;
  esac

  if ! acquire_install_lock "$target_parent/.${target_name}-install.lock"; then
    return 1
  fi

  shopt -s nullglob
  for entry in "$target_parent/.${target_name}-link-"*; do
    if [[ -L "$entry" || -f "$entry" ]]; then
      rm -f "$entry"
    fi
  done
  shopt -u nullglob

  generation_id="$(date -u +%Y%m%d%H%M%S)-${BASHPID:-$$}"
  transaction_staging="$transaction_versions_root/.staging-$generation_id"
  transaction_generation="$transaction_versions_root/generation-$generation_id"
  if [[ -e "$transaction_staging" || -e "$transaction_generation" ]]; then
    echo 'Could not allocate a unique quotabot payload generation.' >&2
    return 1
  fi
  mkdir "$transaction_staging"
  if [[ "$payload_kind" == "macos-app" ]]; then
    ditto "$source" "$transaction_staging"
  else
    cp -R "$source"/. "$transaction_staging"/
  fi
  case "$payload_kind" in
    cli)
      if [[ ! -x "$transaction_staging/bin/quotabot" || \
            ! -d "$transaction_staging/lib" ]]; then
        echo 'Could not stage a complete quotabot CLI payload.' >&2
        return 1
      fi
      ;;
    linux-desktop)
      if [[ ! -x "$transaction_staging/quotabot" ]]; then
        echo 'Could not stage the Linux desktop bundle.' >&2
        return 1
      fi
      ;;
    macos-app)
      if [[ ! -x "$transaction_staging/Contents/MacOS/quotabot" ]]; then
        echo 'Could not stage the macOS app bundle.' >&2
        return 1
      fi
      ;;
    *)
      echo "Unknown quotabot payload kind: $payload_kind" >&2
      return 1
      ;;
  esac
  mv "$transaction_staging" "$transaction_generation"
  transaction_staging=""
  transaction_link="$target_parent/.${target_name}-link-$generation_id"
  ln -s "$versions_name/$(basename "$transaction_generation")" "$transaction_link"

  previous_generation=""
  if [[ -L "$transaction_target" ]]; then
    if ! previous_generation="$(validated_previous_generation \
      "$transaction_target" "$versions_name" "$transaction_versions_root")"; then
      return 1
    fi
  elif [[ -d "$transaction_target" ]]; then
    transaction_legacy_backup="$transaction_versions_root/legacy-$generation_id"
    mv "$transaction_target" "$transaction_legacy_backup"
    transaction_legacy_moved=1
    previous_generation="$transaction_legacy_backup"
  elif [[ -e "$transaction_target" ]]; then
    echo "Refusing to replace a non-directory install target: $transaction_target" >&2
    return 1
  fi

  if ! activate_install_link "$transaction_link" "$transaction_target"; then
    if [[ "$transaction_legacy_moved" -eq 1 && \
          ! -e "$transaction_target" && ! -L "$transaction_target" ]]; then
      mv "$transaction_legacy_backup" "$transaction_target"
      transaction_legacy_moved=0
      previous_generation=""
    fi
    echo 'Could not activate the new quotabot bundle; the previous install was restored.' >&2
    return 1
  fi
  transaction_link=""
  transaction_committed=1
  active_path="$transaction_generation"

  # Retain only the active generation and its immediate predecessor. Any
  # abandoned staging directories are safe to remove while the lock is held.
  shopt -s nullglob
  for entry in "$transaction_versions_root"/.staging-*; do
    safe_remove_versioned_tree "$entry" || true
  done
  for entry in \
    "$transaction_versions_root"/generation-* \
    "$transaction_versions_root"/legacy-*; do
    if [[ "$entry" != "$active_path" && "$entry" != "$previous_generation" ]]; then
      safe_remove_versioned_tree "$entry" || true
    fi
  done
  shopt -u nullglob

  release_install_lock
  reset_transaction_state
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

# Each release lives in a complete versioned directory. The stable install path
# is one symlink, so upgrades become visible through one atomic rename.
install_versioned_tree "$extract_dir" "$INSTALL_ROOT" cli

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
