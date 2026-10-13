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
if [[ "$VERSION" != "latest" && ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
  echo "Invalid QUOTABOT_VERSION value. Expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N." >&2
  exit 1
fi

requires_packaged_updater_scripts() {
  local requested="$1"
  local major minor patch rc
  [[ "$requested" != latest ]] || return 1
  [[ "$requested" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.([0-9]+))?$ ]] || return 2
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))
  rc="${BASH_REMATCH[5]:-}"
  (( major > 0 )) && return 0
  (( minor > 10 )) && return 0
  (( minor < 10 )) && return 1
  (( patch > 0 )) && return 0
  [[ -z "$rc" ]] && return 0
  (( 10#$rc >= 16 ))
}

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
desktop_work=""
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
  if [[ -n "${desktop_work:-}" ]]; then
    rm -rf "$desktop_work"
  fi
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
if requires_packaged_updater_scripts "$VERSION" &&
   [[ ! -f "$extract_dir/lib/install.ps1" || ! -x "$extract_dir/lib/install.sh" ]]; then
  echo "Downloaded archive did not contain the packaged updater scripts" >&2
  exit 1
fi
reported_version=$("$extract_dir/bin/quotabot" --version)
if [[ "$VERSION" == latest ]]; then
  if [[ ! "$reported_version" =~ ^quotabot\ [0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
    echo "Downloaded quotabot executable reported an unexpected version: $reported_version" >&2
    exit 1
  fi
elif [[ "$reported_version" != "quotabot ${VERSION#v}" ]]; then
  echo "Downloaded quotabot executable reported an unexpected version: $reported_version" >&2
  exit 1
fi

stop_managed_executable() {
  local target="$1"
  local line pid args
  local -a ps_args
  managed_desktop_was_running=0
  if [[ "$(uname -s)" == Darwin ]]; then
    ps_args=(-axo pid=,command=)
  else
    ps_args=(-eo pid=,args=)
  fi
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    args="${line#"$pid"}"
    args="${args#"${args%%[![:space:]]*}"}"
    case "$args" in
      "$target"|"$target "*)
        if [[ -n "$pid" && "$pid" != "$$" && "$pid" != "$PPID" ]]; then
          kill "$pid" 2>/dev/null || true
          managed_desktop_was_running=1
        fi
        ;;
    esac
  done < <(ps "${ps_args[@]}")
}

download_verified_release_asset() {
  local asset="$1"
  local destination_dir="$2"
  local release_tag="$3"
  local asset_url expected actual
  asset_url="https://github.com/${REPO}/releases/download/${release_tag}/${asset}"
  mkdir -p "$destination_dir"
  curl -fsSL "$asset_url" -o "$destination_dir/$asset"
  curl -fsSL "${asset_url}.sha256" -o "$destination_dir/$asset.sha256"
  expected=$(awk 'NR==1 {print tolower($1)}' "$destination_dir/$asset.sha256")
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Invalid checksum file for ${asset}" >&2
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$destination_dir/$asset" | awk '{print tolower($1)}')
  else
    actual=$(shasum -a 256 "$destination_dir/$asset" | awk '{print tolower($1)}')
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for ${asset}" >&2
    return 1
  fi
}

# portable-desktop-skew: begin
# Read a Flutter version.json without following a symlink or reading past 4 KiB.
read_flutter_version_json() {
  local file="$1"
  local size="" content="" version=""
  if [[ ! -f "$file" || -L "$file" ]]; then
    return 0
  fi
  size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')" || return 0
  if [[ ! "$size" =~ ^[0-9]+$ || "$size" -lt 1 || "$size" -gt 4096 ]]; then
    return 0
  fi
  content="$(head -c 4096 "$file" 2>/dev/null || true)"
  content="${content//$'\n'/}"
  if [[ ! "$content" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    return 0
  fi
  version="${BASH_REMATCH[1]%%+*}"
  if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$ ]]; then
    return 0
  fi
  printf '%s\n' "$version"
}

read_desktop_bundle_version() {
  local bundle="$1"
  local platform="$2"
  local version="" plist="" content=""
  if [[ "$platform" == "darwin" ]]; then
    version="$(read_flutter_version_json "$bundle/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/version.json" || true)"
    if [[ -n "$version" ]]; then
      printf '%s\n' "$version"
      return 0
    fi
    version="$(read_flutter_version_json "$bundle/Contents/Frameworks/App.framework/Resources/flutter_assets/version.json" || true)"
    if [[ -n "$version" ]]; then
      printf '%s\n' "$version"
      return 0
    fi
    plist="$bundle/Contents/Info.plist"
    if [[ -f "$plist" && ! -L "$plist" ]]; then
      content="$(head -c 65536 "$plist" 2>/dev/null || true)"
      content="${content//$'\n'/}"
      if [[ "$content" =~ \<key\>[[:space:]]*CFBundleShortVersionString[[:space:]]*\</key\>[[:space:]]*\<string\>([^<]+)\</string\> ]]; then
        version="${BASH_REMATCH[1]%%+*}"
        version="${version#"${version%%[![:space:]]*}"}"
        version="${version%"${version##*[![:space:]]}"}"
        if [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$ ]]; then
          printf '%s\n' "$version"
        fi
      fi
    fi
    return 0
  fi
  read_flutter_version_json "$bundle/data/flutter_assets/version.json" || true
}

# Name a desktop bundle on a different version. This only reads one directory
# level and does not replace, stop, or delete the copy.
report_hand_extracted_desktop_skew() {
  local cli_version="$1"
  local root="" asset="" releases="" child="" name="" version=""
  local examined=0 shown=0 matched=0 omitted=0 nullglob_was=0
  if [[ ! "$cli_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$ ]]; then
    return 0
  fi
  if [[ ! "${REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    return 0
  fi
  case "${OS:-}" in
    linux)
      root="${HOME}/.local/share/quotabot-desktop"
      asset="the desktop archive for this operating system"
      if [[ "$ARCH" == "x64" ]]; then asset="quotabot-linux-x64-desktop.tar.gz"; fi
      ;;
    darwin)
      root="${HOME}/Applications"
      asset="the desktop archive for this operating system"
      if [[ "$ARCH" == "arm64" ]]; then asset="quotabot-darwin-arm64-desktop.zip"; fi
      ;;
    *)
      return 0
      ;;
  esac
  releases="https://github.com/${REPO}/releases/tag/v${cli_version}"
  if [[ "$OS" == "linux" && -x "${root}/quotabot" ]]; then
    version="$(read_desktop_bundle_version "$root" linux || true)"
    if [[ -n "$version" && "$version" != "$cli_version" ]]; then
      matched=$((matched + 1))
      if [[ "$shown" -lt 8 ]]; then
        shown=$((shown + 1))
        printf '%s\n' "Managed desktop ${version} at ${root} differs from CLI ${cli_version}. Run \"quotabot update --force\" to replace that managed install. Download ${asset} from ${releases}, verify the .sha256 sidecar, and replace only that managed copy."
      fi
    fi
  fi
  if [[ "$OS" == "darwin" && -x "${HOME}/Applications/quotabot.app/Contents/MacOS/quotabot" ]]; then
    version="$(read_desktop_bundle_version "${HOME}/Applications/quotabot.app" darwin || true)"
    if [[ -n "$version" && "$version" != "$cli_version" ]]; then
      matched=$((matched + 1))
      if [[ "$shown" -lt 8 ]]; then
        shown=$((shown + 1))
        printf '%s\n' "Managed desktop ${version} at ${HOME}/Applications/quotabot.app differs from CLI ${cli_version}. Run \"quotabot update --force\" to replace that managed install. Download ${asset} from ${releases}, verify the .sha256 sidecar, and replace only that managed copy."
      fi
    fi
  fi
  if [[ -d "$root" && ! -L "$root" ]]; then
    if shopt -q nullglob; then
      nullglob_was=1
    else
      shopt -s nullglob
    fi
    for child in "$root"/*; do
      if [[ "$examined" -ge 32 ]]; then
        break
      fi
      examined=$((examined + 1))
      if [[ ! -d "$child" || -L "$child" ]]; then
        continue
      fi
      name="$(basename -- "$child")"
      if [[ ! "$name" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
        continue
      fi
      if [[ "$OS" == "darwin" && ! "$name" =~ ^quotabot-.+\.app$ ]]; then
        continue
      fi
      if [[ "$OS" == "linux" && ( "$name" == "data" || "$name" == "lib" ) ]]; then
        continue
      fi
      version="$(read_desktop_bundle_version "$child" "$OS" || true)"
      if [[ -z "$version" || "$version" == "$cli_version" ]]; then
        continue
      fi
      matched=$((matched + 1))
      if [[ "$shown" -ge 8 ]]; then
        continue
      fi
      shown=$((shown + 1))
      printf '%s\n' "Hand-extracted desktop ${version} at ${child} differs from CLI ${cli_version} and was left in place. Download ${asset} from ${releases}, verify the .sha256 sidecar, extract it into a new directory, quit the old copy, and launch the new executable."
    done
    if [[ "$nullglob_was" -eq 0 ]]; then
      shopt -u nullglob
    fi
  fi
  omitted=$((matched - shown))
  if [[ "$omitted" -eq 1 ]]; then
    printf '%s\n' "1 more desktop copy differs from CLI ${cli_version} and was left in place."
  elif [[ "$omitted" -gt 1 ]]; then
    printf '%s\n' "${omitted} more desktop copies differ from CLI ${cli_version} and were left in place."
  fi
  return 0
}
# portable-desktop-skew: end

# A managed desktop install follows the same tag as the CLI. A missing managed
# app stays absent, and a hand-extracted versioned copy is left where it is.
managed_desktop=""
desktop_asset=""
desktop_kind=""
managed_desktop_was_running=0
case "$OS" in
  darwin)
    if [[ -x "${HOME}/Applications/quotabot.app/Contents/MacOS/quotabot" ]]; then
      managed_desktop="${HOME}/Applications/quotabot.app"
      desktop_asset="quotabot-darwin-${ARCH}-desktop.zip"
      desktop_kind="macos-app"
    fi
    ;;
  linux)
    if [[ -x "${HOME}/.local/share/quotabot-desktop/quotabot" ]]; then
      managed_desktop="${HOME}/.local/share/quotabot-desktop"
      desktop_asset="quotabot-linux-${ARCH}-desktop.tar.gz"
      desktop_kind="linux-desktop"
    fi
    ;;
esac
desktop_work=""
if [[ -n "$managed_desktop" ]]; then
  echo "Updating the managed desktop app from ${VERSION}"
  desktop_work="$(mktemp -d)"
  download_verified_release_asset \
    "$desktop_asset" "$desktop_work" "v${reported_version#quotabot }"
  mkdir -p "$desktop_work/expanded"
  if [[ "$desktop_kind" == macos-app ]]; then
    ditto -x -k "$desktop_work/$desktop_asset" "$desktop_work/expanded"
    if [[ ! -x "$desktop_work/expanded/quotabot.app/Contents/MacOS/quotabot" ]]; then
      echo "Downloaded desktop archive did not contain quotabot.app" >&2
      exit 1
    fi
    stop_managed_executable "$managed_desktop/Contents/MacOS/quotabot"
    install_versioned_tree \
      "$desktop_work/expanded/quotabot.app" "$managed_desktop" macos-app
  else
    tar -xzf "$desktop_work/$desktop_asset" -C "$desktop_work/expanded"
    if [[ ! -x "$desktop_work/expanded/quotabot" ]]; then
      echo "Downloaded desktop archive did not contain quotabot" >&2
      exit 1
    fi
    stop_managed_executable "$managed_desktop/quotabot"
    install_versioned_tree \
      "$desktop_work/expanded" "$managed_desktop" linux-desktop
  fi
  rm -rf "$desktop_work"
  desktop_work=""
fi

# Each release lives in a complete versioned directory. The stable install path
# is one symlink, so upgrades become visible through one atomic rename.
if ! install_versioned_tree "$extract_dir" "$INSTALL_ROOT" cli; then
  if [[ -n "$managed_desktop" ]]; then
    echo "CLI activation failed after the managed desktop app was updated." >&2
  fi
  exit 1
fi

# Keep the PATH shim valid until its complete replacement is ready.
wrapper_tmp=$(mktemp "$INSTALL_DIR/.quotabot.XXXXXX")
printf -v wrapper_install_root '%q' "$INSTALL_ROOT"
cat > "$wrapper_tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
install_root=$wrapper_install_root
install_parent="\${install_root%/*}"
target_name="\${install_root##*/}"
versions_name=".\${target_name}-versions"
active_relative="\$(readlink "\$install_root")"
generation_name="\${active_relative#"\$versions_name"/}"
if [[ "\$active_relative" != "\$versions_name/\$generation_name" ||
      "\$generation_name" == */* ||
      ! "\$generation_name" =~ ^(generation|legacy)-[0-9]{14}-[0-9]+$ ]]; then
  echo "quotabot install target is invalid: \$install_root" >&2
  exit 1
fi
exec "\$install_parent/\$active_relative/bin/quotabot" "\$@"
EOF
chmod +x "$wrapper_tmp"
mv -f "$wrapper_tmp" "$INSTALL_DIR/$BINARY_NAME"
wrapper_tmp=""

if [[ "$managed_desktop_was_running" -eq 1 && -n "$managed_desktop" ]]; then
  if [[ "$OS" == darwin ]]; then
    open "$managed_desktop"
  else
    nohup "$managed_desktop/quotabot" >/dev/null 2>&1 &
    disown || true
  fi
  echo "Restarted the managed desktop app."
fi

# PATH check. Persist ~/.local/bin so a new terminal can find quotabot.
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  export PATH="$INSTALL_DIR:$PATH"
  marker="# quotabot PATH"
  line="export PATH=\"$INSTALL_DIR:\$PATH\""
  profile=""
  case "${SHELL##*/}" in
    zsh)
      if [[ -f "$HOME/.zprofile" || ! -f "$HOME/.zshrc" ]]; then
        profile="$HOME/.zprofile"
      else
        profile="$HOME/.zshrc"
      fi
      ;;
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then
        profile="$HOME/.bashrc"
      elif [[ -f "$HOME/.bash_profile" ]]; then
        profile="$HOME/.bash_profile"
      else
        profile="$HOME/.bashrc"
      fi
      ;;
    fish)
      mkdir -p "$HOME/.config/fish"
      profile="$HOME/.config/fish/config.fish"
      line="fish_add_path \"$INSTALL_DIR\""
      ;;
    *)
      profile="$HOME/.profile"
      ;;
  esac
  if [[ -n "$profile" ]] && grep -Fqs "$marker" "$profile" 2>/dev/null; then
    echo "PATH entry already present in $profile"
  elif [[ -n "$profile" ]]; then
    {
      printf '\n%s\n' "$marker"
      printf '%s\n' "$line"
    } >> "$profile"
    echo "Added $INSTALL_DIR to PATH in $profile (open a new terminal)."
  fi
fi

report_hand_extracted_desktop_skew "${reported_version#quotabot }" || true

echo ""
echo "quotabot installed to $INSTALL_ROOT"
echo ""
echo "Next steps:"
echo "  quotabot doctor"
echo "  quotabot top"
echo "  Host apps already signed in here need no extra login."
echo "  Optional idle-machine grants: quotabot login claude|codex|grok|antigravity"
echo ""
echo "Re-run this script anytime to update."
