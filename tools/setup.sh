#!/usr/bin/env bash
# One-command setup for quotabot from source on macOS and Linux.
#
# Builds and installs the quotabot CLI, and (by default) the desktop app, then
# runs `quotabot doctor`. Idempotent: safe to re-run after a `git pull`.
# No quotabot account or telemetry is used. `doctor` reads quota metadata only:
# no prompts, code, inference requests, or usage-token-spending calls.
# Missing desktop OS build tools skip the tray app and still install the CLI.
# If Dart is missing or this checkout cannot compile, setup installs the
# checksum-verified release CLI instead of failing.
#
# An AI agent can run this unattended:  bash tools/setup.sh --cli-only
#
# Usage:
#   bash tools/setup.sh             # CLI + desktop app when tools are present
#   bash tools/setup.sh --cli-only  # CLI only (no Flutter desktop build)

set -euo pipefail

cli_only=0
explicit_cli_only=0
desktop_skipped=0
for arg in "$@"; do
  case "$arg" in
    --cli-only) cli_only=1; explicit_cli_only=1 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
collector="$root/collector"
app="$root/app"
install_root="$HOME/.local/share/quotabot"
install_dir="$HOME/.local/bin"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok() { printf '\033[32m    %s\033[0m\n' "$1"; }
warn() { printf '\033[33m    %s\033[0m\n' "$1"; }

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  darwin*) os=darwin ;;
  linux*) os=linux ;;
  mingw*|msys*|cygwin*)
    pwsh_args=()
    if [ "$cli_only" -eq 1 ]; then
      pwsh_args+=(-CliOnly)
    fi
    if command -v pwsh >/dev/null 2>&1; then
      exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$script_dir/setup.ps1" "${pwsh_args[@]}"
    fi
    if command -v powershell >/dev/null 2>&1; then
      exec powershell -NoProfile -ExecutionPolicy Bypass -File "$script_dir/setup.ps1" "${pwsh_args[@]}"
    fi
    echo "On Windows, run: pwsh tools/setup.ps1" >&2
    exit 1
    ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) arch=x64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

posix_desktop_prereq_reason() {
  if ! command -v flutter >/dev/null 2>&1; then
    printf '%s\n' 'flutter was not found on PATH'
    return 1
  fi
  if [ "$os" = darwin ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      printf '%s\n' 'Xcode command-line tools are not selected; run xcode-select --install'
      return 1
    fi
  else
    missing=()
    for cmd in clang cmake pkg-config; do
      command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! command -v ninja >/dev/null 2>&1 && ! command -v ninja-build >/dev/null 2>&1; then
      missing+=("ninja")
    fi
    if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists gtk+-3.0; then
      missing+=("gtk+-3.0 (libgtk-3-dev)")
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
      printf '%s\n' "missing Linux desktop build tools: ${missing[*]}"
      return 1
    fi
  fi
  return 0
}

build_desktop_app() {
  # shellcheck source=posix-space-safe-dart.sh
  . "$script_dir/posix-space-safe-dart.sh"
  quotabot_enable_space_safe_dart "$root" flutter >/dev/null || true
  (
    cd "$app" || exit 1
    flutter pub get --enforce-lockfile || exit 1
    if [ "$os" = darwin ]; then
      flutter config --enable-macos-desktop >/dev/null || true
      flutter build macos --release --no-pub || exit 1
    else
      flutter config --enable-linux-desktop >/dev/null || true
      flutter build linux --release --no-pub || exit 1
    fi
  ) || {
    quotabot_restore_space_safe_dart
    return 1
  }
  quotabot_restore_space_safe_dart
  if [ "$os" = darwin ]; then
    desktop_source="$app/build/macos/Build/Products/Release/quotabot.app"
    desktop_kind="macos-app"
    [ -x "$desktop_source/Contents/MacOS/quotabot" ] || return 1
  else
    desktop_source="$app/build/linux/$arch/release/bundle"
    desktop_kind="linux-desktop"
    [ -x "$desktop_source/quotabot" ] || return 1
  fi
  return 0
}

append_local_bin_to_profile() {
  local install_dir="$1"
  local marker="# quotabot PATH"
  local line="export PATH=\"$install_dir:\$PATH\""
  local profile=""
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
      line="fish_add_path \"$install_dir\""
      ;;
    *)
      profile="$HOME/.profile"
      ;;
  esac
  if grep -Fqs "$marker" "$profile" 2>/dev/null; then
    ok "PATH entry already present in $profile"
    return 0
  fi
  {
    printf '\n%s\n' "$marker"
    printf '%s\n' "$line"
  } >> "$profile"
  ok "Added $install_dir to PATH in $profile (open a new terminal)"
}

install_dart_run_shim() {
  mkdir -p "$install_dir"
  cat > "$install_dir/quotabot" <<EOF
#!/usr/bin/env bash
cd "$collector" || exit 1
exec dart run bin/collect.dart "\$@"
EOF
  chmod +x "$install_dir/quotabot"
}

show_first_run() {
  local python_bin
  python_bin="$(command -v python3 || command -v python || true)"
  [ -n "$python_bin" ] || return 0
  "$install_dir/quotabot" --json 2>/dev/null |
    "$python_bin" "$script_dir/setup_first_run.py"
}

source_release_tag() {
  local raw version
  [ -f "$app/pubspec.yaml" ] || return 1
  raw="$(awk '/^version:[[:space:]]*/ {print $2; exit}' "$app/pubspec.yaml")"
  version="${raw%%+*}"
  if [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
    printf 'v%s\n' "$version"
    return 0
  fi
  return 1
}

install_portable_desktop() {
  local repo version asset url work archive sum expected actual dest expanded
  local http_code
  repo="${QUOTABOT_REPO:-blisspixel/quotabot}"
  if [ -n "${QUOTABOT_VERSION:-}" ]; then
    version="$QUOTABOT_VERSION"
  else
    version="$(source_release_tag || true)"
    version="${version:-latest}"
  fi
  case "$os" in
    darwin)
      [ "$arch" = arm64 ] || return 1
      asset="quotabot-darwin-arm64-desktop.zip"
      dest="$HOME/Applications/quotabot.app"
      ;;
    linux)
      asset="quotabot-linux-${arch}-desktop.tar.gz"
      dest="$HOME/.local/share/quotabot-desktop"
      ;;
    *)
      return 1
      ;;
  esac
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    return 1
  fi
  if [[ "$version" != "latest" && ! "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
    return 1
  fi
  if [ "$version" = latest ]; then
    url="https://github.com/${repo}/releases/latest/download/${asset}"
  else
    url="https://github.com/${repo}/releases/download/${version}/${asset}"
  fi
  work="$(mktemp -d)"
  archive="$work/$asset"
  sum="$work/$asset.sha256"
  expanded="$work/expanded"
  step 'Installing the portable desktop app'
  http_code="$(curl -sSL -o "$archive" -w '%{http_code}' "$url")" || http_code=000
  if [ "$http_code" != 200 ]; then
    rm -rf "$work"
    if [ "$http_code" = 404 ]; then
      warn "Portable desktop install skipped: no published release ${version} provides ${asset}." >&2
      warn "The installed desktop app is unchanged. Build it from source once desktop build tools are ready, or re-run setup after that release is published." >&2
    else
      warn "Portable desktop install skipped: download failed (HTTP ${http_code})." >&2
    fi
    return 1
  fi
  if ! curl -fsSL "${url}.sha256" -o "$sum"; then
    rm -rf "$work"
    warn "Portable desktop install skipped: the checksum sidecar download failed." >&2
    return 1
  fi
  expected="$(awk 'NR == 1 {print tolower($1)}' "$sum")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    rm -rf "$work"
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | awk '{print tolower($1)}')"
  else
    actual="$(shasum -a 256 "$archive" | awk '{print tolower($1)}')"
  fi
  if [ "$expected" != "$actual" ]; then
    rm -rf "$work"
    return 1
  fi
  if [ "$os" = darwin ]; then
    mkdir -p "$HOME/Applications"
    mkdir -p "$expanded"
    if ! ditto -x -k "$archive" "$expanded" || \
       [ ! -x "$expanded/quotabot.app/Contents/MacOS/quotabot" ] || \
       ! install_versioned_single \
         "$expanded/quotabot.app" "$dest" macos-app; then
      rm -rf "$work"
      return 1
    fi
    rm -rf "$work"
    printf '%s\n' "$dest"
    return 0
  fi
  mkdir -p "$expanded"
  if ! tar -xzf "$archive" -C "$expanded" || \
     [ ! -x "$expanded/quotabot" ] || \
     ! install_versioned_single "$expanded" "$dest" linux-desktop; then
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
  printf '%s\n' "$dest/quotabot"
}

open_quotabot_after_setup() {
  local launched=0
  if [ "$explicit_cli_only" -eq 1 ]; then
    ok 'Skipped app launch for CLI-only setup'
    return 0
  fi
  if [ "$explicit_cli_only" -eq 0 ] && [ "$desktop_skipped" -eq 1 ]; then
    install_portable_desktop >/dev/null || true
  fi
  if [ "$explicit_cli_only" -eq 0 ] && [ "$os" = darwin ] && [ -x "$HOME/Applications/quotabot.app/Contents/MacOS/quotabot" ]; then
    step 'Opening quotabot'
    open "$HOME/Applications/quotabot.app"
    ok 'Opened the desktop app'
    launched=1
  elif [ "$explicit_cli_only" -eq 0 ] && [ "$os" = linux ] && [ -x "$HOME/.local/share/quotabot-desktop/quotabot" ]; then
    step 'Opening quotabot'
    nohup "$HOME/.local/share/quotabot-desktop/quotabot" >/dev/null 2>&1 &
    ok 'Opened the desktop app'
    launched=1
    if [ "$desktop_skipped" -eq 1 ]; then
      bash "$script_dir/write-desktop-entry.sh" \
        "$script_dir/quotabot.desktop" \
        "$HOME/.local/share/quotabot-desktop/quotabot" \
        "$HOME/.local/share/applications/quotabot.desktop" || true
    fi
  fi
  if [ "$launched" -eq 0 ]; then
    step 'Opening quotabot top'
    if command -v x-terminal-emulator >/dev/null 2>&1; then
      x-terminal-emulator -e "$install_dir/quotabot" top >/dev/null 2>&1 &
    elif command -v osascript >/dev/null 2>&1; then
      osascript -e "tell application \"Terminal\" to do script \"$install_dir/quotabot top\"" >/dev/null 2>&1 || true
    fi
    ok 'Opened quotabot top when a terminal launcher was available'
  fi
}

step 'Locating the Dart toolchain'
if command -v dart >/dev/null 2>&1; then
  ok "$(dart --version 2>&1 | head -n1)"
else
  warn 'Dart/Flutter not found. Using the checksum-verified release CLI instead of compiling this checkout.'
fi

if [ "$cli_only" -eq 0 ]; then
  step 'Checking desktop build tools'
  if desktop_reason="$(posix_desktop_prereq_reason)"; then
    ok 'Desktop build tools found'
  else
    desktop_skipped=1
    cli_only=1
    warn "Desktop skipped: $desktop_reason. Installing the CLI only. Re-run bash tools/setup.sh after the desktop toolchain is ready to add the tray app."
  fi
fi

source_cli=0
used_release=0
used_shim=0
asset="$root/release/quotabot-${os}-${arch}.tar.gz"

if command -v dart >/dev/null 2>&1; then
  step 'Building the quotabot CLI'
  if (cd "$collector" && \
      dart pub get --enforce-lockfile >/dev/null && \
      bash "$script_dir/package-cli.sh") && [ -f "$asset" ]; then
    source_cli=1
  else
    warn 'Source CLI build failed. Falling back to the release CLI.'
  fi
fi

if [ "$source_cli" -eq 0 ]; then
  desktop_skipped=1
  cli_only=1
  step 'Installing the checksum-verified release CLI'
  if bash "$root/install.sh"; then
    used_release=1
    ok 'Installed the release CLI'
  elif command -v dart >/dev/null 2>&1; then
    warn 'Release CLI download failed. Installing a dart-run shim from this checkout.'
    install_dart_run_shim
    used_shim=1
    ok 'Installed dart-run shim'
  else
    echo "Could not compile this checkout and could not download the release CLI." >&2
    exit 1
  fi
fi

desktop_source=""
desktop_kind=""
if [ "$cli_only" -eq 0 ]; then
  step 'Building the desktop app (this takes a few minutes)'
  if build_desktop_app; then
    ok 'Built the desktop app'
  else
    desktop_skipped=1
    cli_only=1
    desktop_source=""
    desktop_kind=""
    warn 'Desktop build failed. Installing the CLI only. Re-run bash tools/setup.sh after the desktop toolchain is repaired.'
  fi
fi

if [ "$source_cli" -eq 1 ]; then
  step "Installing the CLI to $install_root"
fi
mkdir -p "$install_dir"
tmpdir="$(mktemp -d)"
pair_in_progress=0
pair_count=0
pair_lock_owner=""
pair_source=()
pair_kind=()
pair_target=()
pair_target_parent=()
pair_target_name=()
pair_versions_name=()
pair_versions_root=()
pair_lock_path=()
pair_lock_held=()
pair_previous=()
pair_was_legacy=()
pair_legacy_backup=()
pair_legacy_moved=()
pair_staging=()
pair_generation=()
pair_link=()
pair_activated=()
wrapper_tmp=""
# BEGIN POSIX INSTALL TRANSACTION FUNCTIONS
safe_remove_tree_in_versions() {
  local versions_root="$1"
  local candidate="$2"
  local candidate_name
  case "$candidate" in
    "$versions_root"/*)
      candidate_name="${candidate#"$versions_root"/}"
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
cleanup_setup() {
  status=$?
  set +e
  if [[ "$pair_in_progress" -eq 1 ]]; then
    rollback_versioned_pair || true
  fi
  if [[ -n "$wrapper_tmp" ]]; then
    rm -f "$wrapper_tmp"
  fi
  rm -rf "$tmpdir"
  return "$status"
}

activate_install_link() {
  local candidate="$1"
  local target="$2"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    mv "$candidate" "$target"
  elif [[ "$os" == darwin ]]; then
    mv -fh "$candidate" "$target"
  else
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
reset_pair_transaction_state() {
  pair_in_progress=0
  pair_count=0
  pair_lock_owner=""
  pair_source=()
  pair_kind=()
  pair_target=()
  pair_target_parent=()
  pair_target_name=()
  pair_versions_name=()
  pair_versions_root=()
  pair_lock_path=()
  pair_lock_held=()
  pair_previous=()
  pair_was_legacy=()
  pair_legacy_backup=()
  pair_legacy_moved=()
  pair_staging=()
  pair_generation=()
  pair_link=()
  pair_activated=()
}
configure_pair_item() {
  local index="$1"
  local source="$2"
  local requested_target="$3"
  local payload_kind="$4"
  local target_parent target_name versions_name versions_root

  target_parent="$(dirname "$requested_target")"
  target_name="$(basename "$requested_target")"
  case "$target_name" in
    '' | '.' | '..' | *[!A-Za-z0-9._-]*)
      echo "Invalid install target name: $target_name" >&2
      return 1
      ;;
  esac
  mkdir -p "$target_parent" || return 1
  target_parent="$(cd "$target_parent" && pwd -P)" || return 1
  versions_name=".${target_name}-versions"
  versions_root="$target_parent/$versions_name"
  if [[ -L "$versions_root" ]]; then
    echo "Refusing to use a symlink as the quotabot versions directory: $versions_root" >&2
    return 1
  fi
  mkdir -p "$versions_root" || return 1
  versions_root="$(cd "$versions_root" && pwd -P)" || return 1
  case "$versions_root" in
    "$target_parent"/*) ;;
    *)
      echo 'The quotabot versions directory resolved outside its install parent.' >&2
      return 1
      ;;
  esac

  pair_source[$index]="$source"
  pair_kind[$index]="$payload_kind"
  pair_target_parent[$index]="$target_parent"
  pair_target_name[$index]="$target_name"
  pair_target[$index]="$target_parent/$target_name"
  pair_versions_name[$index]="$versions_name"
  pair_versions_root[$index]="$versions_root"
  pair_lock_path[$index]="$target_parent/.${target_name}-install.lock"
  pair_lock_held[$index]=0
  pair_previous[$index]=""
  pair_was_legacy[$index]=0
  pair_legacy_backup[$index]=""
  pair_legacy_moved[$index]=0
  pair_staging[$index]=""
  pair_generation[$index]=""
  pair_link[$index]=""
  pair_activated[$index]=0
}
acquire_pair_lock() {
  local index="$1"
  local lock_path="${pair_lock_path[$index]}"
  local existing_owner owner_is_live stale_lock

  if (set -o noclobber; printf '%s\n' "$pair_lock_owner" > "$lock_path") 2>/dev/null; then
    pair_lock_held[$index]=1
    return 0
  fi
  if [[ ! -f "$lock_path" || -L "$lock_path" ]]; then
    echo "Refusing to recover an invalid quotabot install lock: $lock_path" >&2
    return 1
  fi
  existing_owner="$(cat "$lock_path" 2>/dev/null || true)"
  case "$existing_owner" in
    '' | *[!0-9]*) owner_is_live=0 ;;
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
    return 1
  fi
  stale_lock="$lock_path.stale.$pair_lock_owner"
  if ! mv "$lock_path" "$stale_lock" 2>/dev/null; then
    echo 'Could not recover a stale quotabot install lock.' >&2
    return 1
  fi
  if ! rm -f -- "$stale_lock"; then
    mv "$stale_lock" "$lock_path" 2>/dev/null || true
    echo 'Could not remove a stale quotabot install lock.' >&2
    return 1
  fi
  if ! (set -o noclobber; printf '%s\n' "$pair_lock_owner" > "$lock_path") 2>/dev/null; then
    echo 'Another quotabot install started activating a bundle.' >&2
    return 1
  fi
  pair_lock_held[$index]=1
}
release_pair_locks() {
  local index lock_path
  for ((index = 0; index < pair_count; index++)); do
    if [[ "${pair_lock_held[$index]:-0}" -ne 1 ]]; then
      continue
    fi
    lock_path="${pair_lock_path[$index]}"
    if [[ -f "$lock_path" && \
          "$(cat "$lock_path" 2>/dev/null)" == "$pair_lock_owner" ]]; then
      rm -f "$lock_path"
    fi
    pair_lock_held[$index]=0
  done
}
capture_pair_predecessor() {
  local index="$1"
  local target="${pair_target[$index]}"

  if [[ -L "$target" ]]; then
    if ! pair_previous[$index]="$(validated_previous_generation \
      "$target" "${pair_versions_name[$index]}" \
      "${pair_versions_root[$index]}")"; then
      return 1
    fi
  elif [[ -d "$target" ]]; then
    pair_was_legacy[$index]=1
  elif [[ -e "$target" ]]; then
    echo "Refusing to replace a non-directory install target: $target" >&2
    return 1
  fi
}
stage_pair_item() {
  local index="$1"
  local generation_id entry source payload_kind staging generation link
  local versions_root="${pair_versions_root[$index]}"
  local target_parent="${pair_target_parent[$index]}"
  local target_name="${pair_target_name[$index]}"

  shopt -s nullglob
  for entry in "$target_parent/.${target_name}-link-"* \
    "$target_parent/.${target_name}-rollback-"*; do
    if [[ -L "$entry" || -f "$entry" ]]; then
      rm -f "$entry"
    fi
  done
  for entry in "$versions_root"/.staging-*; do
    safe_remove_tree_in_versions "$versions_root" "$entry" || {
      shopt -u nullglob
      return 1
    }
  done
  shopt -u nullglob

  while :; do
    generation_id="$(date -u +%Y%m%d%H%M%S)-${BASHPID:-$$}${RANDOM}"
    staging="$versions_root/.staging-$generation_id"
    generation="$versions_root/generation-$generation_id"
    if [[ ! -e "$staging" && ! -L "$staging" && \
          ! -e "$generation" && ! -L "$generation" ]]; then
      break
    fi
  done
  pair_staging[$index]="$staging"
  pair_generation[$index]="$generation"
  pair_legacy_backup[$index]="$versions_root/legacy-$generation_id"
  mkdir "$staging" || return 1
  source="${pair_source[$index]}"
  payload_kind="${pair_kind[$index]}"
  if [[ "$payload_kind" == macos-app ]]; then
    ditto "$source" "$staging" || return 1
  else
    cp -R "$source"/. "$staging"/ || return 1
  fi
  case "$payload_kind" in
    cli)
      if [[ ! -x "$staging/bin/quotabot" || ! -d "$staging/lib" ]]; then
        echo 'Could not stage a complete quotabot CLI payload.' >&2
        return 1
      fi
      ;;
    linux-desktop)
      if [[ ! -x "$staging/quotabot" ]]; then
        echo 'Could not stage the Linux desktop bundle.' >&2
        return 1
      fi
      ;;
    macos-app)
      if [[ ! -x "$staging/Contents/MacOS/quotabot" ]]; then
        echo 'Could not stage the macOS app bundle.' >&2
        return 1
      fi
      ;;
    *)
      echo "Unknown quotabot payload kind: $payload_kind" >&2
      return 1
      ;;
  esac
  mv "$staging" "$generation" || return 1
  pair_staging[$index]=""
  link="$target_parent/.${target_name}-link-$generation_id"
  pair_link[$index]="$link"
  ln -s "${pair_versions_name[$index]}/$(basename "$generation")" "$link" || return 1
}
activate_pair_item() {
  local index="$1"
  local target="${pair_target[$index]}"

  if [[ "${pair_was_legacy[$index]}" -eq 1 ]]; then
    if ! mv "$target" "${pair_legacy_backup[$index]}"; then
      echo "Could not preserve the previous install at $target" >&2
      return 1
    fi
    pair_legacy_moved[$index]=1
    pair_previous[$index]="${pair_legacy_backup[$index]}"
  fi
  if ! activate_install_link "${pair_link[$index]}" "$target"; then
    if [[ "${pair_legacy_moved[$index]}" -eq 1 && \
          ! -e "$target" && ! -L "$target" ]]; then
      if mv "${pair_legacy_backup[$index]}" "$target"; then
        pair_legacy_moved[$index]=0
        pair_previous[$index]=""
      fi
    fi
    echo "Could not activate the new quotabot payload at $target" >&2
    return 1
  fi
  pair_link[$index]=""
  pair_activated[$index]=1
}
new_pair_rollback_path() {
  local index="$1"
  local purpose="$2"
  local candidate

  while :; do
    candidate="${pair_target_parent[$index]}/.${pair_target_name[$index]}-rollback-${purpose}-${BASHPID:-$$}${RANDOM}"
    if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}
restore_pair_item() {
  local index="$1"
  local target="${pair_target[$index]}"
  local expected_relative rollback_link displaced_link

  if [[ "${pair_activated[$index]}" -ne 1 ]]; then
    if [[ "${pair_legacy_moved[$index]}" -eq 1 && \
          ! -e "$target" && ! -L "$target" ]]; then
      if ! mv "${pair_legacy_backup[$index]}" "$target"; then
        return 1
      fi
      pair_legacy_moved[$index]=0
      pair_previous[$index]=""
    fi
    return 0
  fi
  expected_relative="${pair_versions_name[$index]}/$(basename "${pair_generation[$index]}")"
  if [[ ! -L "$target" || "$(readlink "$target")" != "$expected_relative" ]]; then
    echo "Cannot safely restore a changed install target: $target" >&2
    return 1
  fi

  if [[ "${pair_legacy_moved[$index]}" -eq 1 ]]; then
    displaced_link="$(new_pair_rollback_path "$index" new)"
    if ! mv "$target" "$displaced_link"; then
      return 1
    fi
    if ! mv "${pair_legacy_backup[$index]}" "$target"; then
      mv "$displaced_link" "$target" || true
      return 1
    fi
    rm -f "$displaced_link"
    pair_legacy_moved[$index]=0
  elif [[ -n "${pair_previous[$index]}" ]]; then
    rollback_link="$(new_pair_rollback_path "$index" previous)"
    if ! ln -s "${pair_versions_name[$index]}/$(basename "${pair_previous[$index]}")" \
      "$rollback_link"; then
      return 1
    fi
    if ! activate_install_link "$rollback_link" "$target"; then
      rm -f "$rollback_link"
      return 1
    fi
  else
    displaced_link="$(new_pair_rollback_path "$index" new)"
    if ! mv "$target" "$displaced_link"; then
      return 1
    fi
    rm -f "$displaced_link"
  fi
  pair_activated[$index]=0
}
rollback_versioned_pair() {
  local index rollback_complete=1

  for ((index = pair_count - 1; index >= 0; index--)); do
    if ! restore_pair_item "$index"; then
      rollback_complete=0
    fi
  done
  for ((index = 0; index < pair_count; index++)); do
    if [[ -n "${pair_link[$index]:-}" ]]; then
      rm -f "${pair_link[$index]}"
      pair_link[$index]=""
    fi
    if [[ -n "${pair_staging[$index]:-}" ]]; then
      safe_remove_tree_in_versions \
        "${pair_versions_root[$index]}" "${pair_staging[$index]}" || rollback_complete=0
      pair_staging[$index]=""
    fi
    if [[ -n "${pair_generation[$index]:-}" && \
          "${pair_activated[$index]:-0}" -eq 0 ]]; then
      safe_remove_tree_in_versions \
        "${pair_versions_root[$index]}" "${pair_generation[$index]}" || rollback_complete=0
      pair_generation[$index]=""
    fi
  done
  if [[ "$rollback_complete" -eq 1 ]]; then
    release_pair_locks
    reset_pair_transaction_state
    return 0
  fi
  echo 'The paired quotabot install rollback was incomplete; recovery payloads were preserved.' >&2
  return 1
}
commit_versioned_pair() {
  local index entry active_path previous_path versions_root

  for ((index = 0; index < pair_count; index++)); do
    active_path="${pair_generation[$index]}"
    previous_path="${pair_previous[$index]}"
    versions_root="${pair_versions_root[$index]}"
    shopt -s nullglob
    for entry in "$versions_root"/.staging-*; do
      safe_remove_tree_in_versions "$versions_root" "$entry" || true
    done
    for entry in "$versions_root"/generation-* "$versions_root"/legacy-*; do
      if [[ "$entry" != "$active_path" && "$entry" != "$previous_path" ]]; then
        safe_remove_tree_in_versions "$versions_root" "$entry" || true
      fi
    done
    shopt -u nullglob
  done
  release_pair_locks
  reset_pair_transaction_state
}
install_versioned_single() {
  local source="$1"
  local target="$2"
  local payload_kind="$3"

  reset_pair_transaction_state
  pair_in_progress=1
  pair_lock_owner="${BASHPID:-$$}"
  if ! configure_pair_item 0 "$source" "$target" "$payload_kind"; then
    rollback_versioned_pair || true
    return 1
  fi
  pair_count=1
  if ! acquire_pair_lock 0 || ! capture_pair_predecessor 0 || \
     ! stage_pair_item 0 || ! activate_pair_item 0; then
    rollback_versioned_pair || true
    return 1
  fi
  commit_versioned_pair
}
install_versioned_pair() {
  local cli_source="$1"
  local cli_target="$2"
  local desktop_source_path="$3"
  local desktop_target="$4"
  local desktop_payload_kind="$5"
  local first_lock=0 second_lock=1
  local LC_ALL=C

  reset_pair_transaction_state
  pair_in_progress=1
  pair_lock_owner="${BASHPID:-$$}"
  if ! configure_pair_item 0 "$cli_source" "$cli_target" cli; then
    rollback_versioned_pair || true
    return 1
  fi
  pair_count=1
  if ! configure_pair_item 1 "$desktop_source_path" "$desktop_target" \
    "$desktop_payload_kind"; then
    rollback_versioned_pair || true
    return 1
  fi
  pair_count=2
  if [[ "${pair_lock_path[0]}" == "${pair_lock_path[1]}" ]]; then
    echo 'The paired install targets unexpectedly share one lock.' >&2
    rollback_versioned_pair || true
    return 1
  fi
  if [[ "${pair_lock_path[1]}" < "${pair_lock_path[0]}" ]]; then
    first_lock=1
    second_lock=0
  fi
  if ! acquire_pair_lock "$first_lock" || ! acquire_pair_lock "$second_lock"; then
    rollback_versioned_pair || true
    return 1
  fi
  if ! capture_pair_predecessor 0 || ! capture_pair_predecessor 1 || \
     ! stage_pair_item 0 || ! stage_pair_item 1; then
    rollback_versioned_pair || true
    return 1
  fi

  # The desktop becomes visible first. If CLI activation then fails, rollback
  # restores the desktop predecessor before either lock is released.
  if ! activate_pair_item 1; then
    rollback_versioned_pair || true
    return 1
  fi
  if ! activate_pair_item 0; then
    rollback_versioned_pair || true
    return 1
  fi
  commit_versioned_pair
}
# END POSIX INSTALL TRANSACTION FUNCTIONS
trap cleanup_setup EXIT

if [ "$source_cli" -eq 1 ]; then
tar -xzf "$asset" -C "$tmpdir"
[ -x "$tmpdir/bin/quotabot" ] || { echo "CLI archive did not contain executable bin/quotabot" >&2; exit 1; }
[ -d "$tmpdir/lib" ] || { echo "CLI archive did not contain lib/" >&2; exit 1; }
[ -f "$tmpdir/lib/install.ps1" ] || { echo "CLI archive did not contain lib/install.ps1" >&2; exit 1; }
[ -x "$tmpdir/lib/install.sh" ] || { echo "CLI archive did not contain executable lib/install.sh" >&2; exit 1; }

desktop_target=""
if [ "$cli_only" -eq 1 ]; then
  install_versioned_single "$tmpdir" "$install_root" cli
elif [ "$desktop_kind" = macos-app ]; then
  applications="$HOME/Applications"
  installed_app="$applications/quotabot.app"
  desktop_target="$installed_app"
  mkdir -p "$applications"
  step 'Activating the CLI and desktop app'
  install_versioned_pair \
    "$tmpdir" "$install_root" "$desktop_source" "$desktop_target" macos-app
else
  applications="$HOME/.local/share/applications"
  installed_bundle="$HOME/.local/share/quotabot-desktop"
  desktop_target="$installed_bundle"
  mkdir -p "$applications"
  step 'Activating the CLI and desktop app'
  install_versioned_pair \
    "$tmpdir" "$install_root" "$desktop_source" "$desktop_target" linux-desktop
fi

wrapper_tmp="$(mktemp "$install_dir/.quotabot.XXXXXX")"
cat > "$wrapper_tmp" <<EOF
#!/usr/bin/env bash
exec "$install_root/bin/quotabot" "\$@"
EOF
chmod +x "$wrapper_tmp"
mv -f "$wrapper_tmp" "$install_dir/quotabot"
wrapper_tmp=""
ok 'Installed quotabot'
fi
case ":$PATH:" in
  *":$install_dir:"*) ok 'Install dir already on PATH' ;;
  *)
    export PATH="$install_dir:$PATH"
    append_local_bin_to_profile "$install_dir"
    ;;
esac

if [ "$cli_only" -eq 0 ]; then
  if [ "$desktop_kind" = macos-app ]; then
    ok "Installed the desktop app to $desktop_target"
  else
    desktop="$HOME/.local/share/applications/quotabot.desktop"
    bash "$script_dir/write-desktop-entry.sh" \
      "$script_dir/quotabot.desktop" "$installed_bundle/quotabot" "$desktop"
    ok "Installed the desktop app to $desktop_target"
    ok "Installed an application-menu entry: $desktop"
  fi
fi

step 'Verifying with quotabot doctor'
"$install_dir/quotabot" doctor || warn 'doctor reported an issue (expected if no provider tools have run yet).'

show_first_run
open_quotabot_after_setup

echo
printf '\033[32mquotabot is set up.\033[0m\n'
echo "  CLI:   quotabot --help"
if [ "$used_release" -eq 1 ]; then
  echo "  Note:  release CLI (this checkout did not compile)"
elif [ "$used_shim" -eq 1 ]; then
  echo "  Note:  dart-run shim from this checkout"
fi
if [ "$explicit_cli_only" -eq 1 ]; then
  echo "  App:   skipped by --cli-only"
elif [ -x "$HOME/Applications/quotabot.app/Contents/MacOS/quotabot" ] || \
     [ -x "$HOME/.local/share/quotabot-desktop/quotabot" ]; then
  echo "  App:   opened"
elif [ "$cli_only" -eq 0 ]; then
  echo "  App:   launch quotabot from your applications menu"
elif [ "$desktop_skipped" -eq 1 ]; then
  echo "  App:   CLI dashboard is available as quotabot top"
fi
echo "  Route: quotabot suggest   (which subscription to use next)"
