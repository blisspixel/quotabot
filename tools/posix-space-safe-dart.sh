#!/usr/bin/env bash
# Map the Dart SDK onto a space-free mirror when the toolchain path contains
# spaces. Dart's native-asset hooks have invoked the SDK through unquoted
# command lines; a path such as /Users/First Last/flutter/... then fails.
# Junctions and 8.3 names are a Windows concern; on POSIX a real hardlink or
# copy of the SDK is the reliable fix. Source this file; do not execute it.

quotabot_restore_space_safe_dart() {
  if [[ -n "${QUOTABOT_SPACE_SAFE_PATH_BACKUP+x}" ]]; then
    PATH="$QUOTABOT_SPACE_SAFE_PATH_BACKUP"
    unset QUOTABOT_SPACE_SAFE_PATH_BACKUP
  fi
  if [[ -n "${QUOTABOT_SPACE_SAFE_DART_SDK_BACKUP+x}" ]]; then
    if [[ -z "$QUOTABOT_SPACE_SAFE_DART_SDK_BACKUP" ]]; then
      unset DART_SDK
    else
      DART_SDK="$QUOTABOT_SPACE_SAFE_DART_SDK_BACKUP"
    fi
    unset QUOTABOT_SPACE_SAFE_DART_SDK_BACKUP
  fi
  if [[ -n "${QUOTABOT_SPACE_SAFE_FLUTTER_ROOT_BACKUP+x}" ]]; then
    if [[ -z "$QUOTABOT_SPACE_SAFE_FLUTTER_ROOT_BACKUP" ]]; then
      unset FLUTTER_ROOT
    else
      FLUTTER_ROOT="$QUOTABOT_SPACE_SAFE_FLUTTER_ROOT_BACKUP"
    fi
    unset QUOTABOT_SPACE_SAFE_FLUTTER_ROOT_BACKUP
  fi
  if [[ -n "${QUOTABOT_SPACE_SAFE_MIRROR:-}" ]]; then
    rm -rf -- "$QUOTABOT_SPACE_SAFE_MIRROR"
    unset QUOTABOT_SPACE_SAFE_MIRROR
  fi
}

quotabot_resolve_dart_sdk() {
  local dart_path bin_dir sdk
  dart_path="$(command -v dart)" || return 1
  bin_dir="$(cd "$(dirname "$dart_path")" && pwd -P)"
  sdk="$bin_dir/cache/dart-sdk"
  if [[ -x "$sdk/bin/dart" ]]; then
    printf '%s\n' "$sdk"
    return 0
  fi
  sdk="$(cd "$bin_dir/.." && pwd -P)"
  if [[ -x "$sdk/bin/dart" ]]; then
    printf '%s\n' "$sdk"
    return 0
  fi
  echo "Unable to resolve the Dart SDK from $dart_path" >&2
  return 1
}

quotabot_space_free_parent() {
  local preferred_root="${1:-}"
  local candidates=()
  local parent
  if [[ -n "$preferred_root" && "$preferred_root" != *' '* ]]; then
    candidates+=("$preferred_root/.setup-cache")
  fi
  if [[ -n "${XDG_CACHE_HOME:-}" && "${XDG_CACHE_HOME}" != *' '* ]]; then
    candidates+=("${XDG_CACHE_HOME%/}/quotabot-build")
  fi
  if [[ -n "${HOME:-}" && "${HOME}" != *' '* ]]; then
    candidates+=("$HOME/.cache/quotabot-build")
  fi
  if [[ -n "${TMPDIR:-}" && "${TMPDIR}" != *' '* ]]; then
    candidates+=("${TMPDIR%/}/quotabot-build")
  fi
  for parent in "${candidates[@]}"; do
    mkdir -p -- "$parent" || true
    if [[ -d "$parent" && "$parent" != *' '* ]]; then
      printf '%s\n' "$parent"
      return 0
    fi
  done
  echo "Unable to create a space-free directory for a Dart SDK mirror." >&2
  return 1
}

quotabot_dart_present() {
  local root="$1"
  [[ -e "$root/bin/dart" || -e "$root/bin/dart.exe" ]]
}

quotabot_mirror_dart_sdk() {
  local source="$1"
  local destination="$2"
  local kind
  try_mirror() {
    kind="$1"
    shift
    rm -rf -- "$destination"
    mkdir -p "$destination"
    if "$@" 2>/dev/null && quotabot_dart_present "$destination"; then
      return 0
    fi
    return 1
  }
  if try_mirror hardlink cp -a --link "$source"/. "$destination"/ ||
     try_mirror hardlink cp -al "$source"/. "$destination"/ ||
     try_mirror copy cp -cR "$source"/. "$destination"/ ||
     try_mirror copy cp -R "$source"/. "$destination"/; then
    printf '%s\n' "$kind"
    return 0
  fi
  echo "Unable to mirror the Dart SDK from $source to $destination" >&2
  return 1
}

quotabot_flutter_present() {
  local root="$1"
  [[ -f "$root/bin/cache/flutter_tools.snapshot" ]] &&
    [[ -f "$root/packages/flutter_tools/.dart_tool/package_config.json" ]] &&
    quotabot_dart_present "$root/bin/cache/dart-sdk"
}

quotabot_resolve_flutter_root() {
  local flutter_path bin_dir root
  flutter_path="$(command -v flutter)" || return 1
  bin_dir="$(cd "$(dirname "$flutter_path")" && pwd)"
  root="$(cd "$bin_dir/.." && pwd)"
  if quotabot_flutter_present "$root"; then
    printf '%s\n' "$root"
    return 0
  fi
  echo "Flutter on PATH is incomplete under $root" >&2
  return 1
}

quotabot_link_or_copy() {
  local source="$1"
  local destination="$2"
  if [[ -d "$source" ]]; then
    ln -s "$source" "$destination" 2>/dev/null && return 0
    cp -R "$source" "$destination"
    return
  fi
  ln -s "$source" "$destination" 2>/dev/null && return 0
  cp "$source" "$destination"
}

# Copy launcher scripts so `pwd -P` from dest/bin stays space-free. Symlink
# the rest of the SDK; only dart-sdk is physically mirrored because native-asset
# hooks invoke it through unquoted command lines.
quotabot_mirror_flutter_sdk() {
  local source="$1"
  local destination="$2"
  local item name kind
  rm -rf -- "$destination"
  mkdir -p "$destination/bin/cache"
  for item in "$source"/*; do
    [[ -e "$item" ]] || continue
    name="$(basename "$item")"
    [[ "$name" == bin ]] && continue
    quotabot_link_or_copy "$item" "$destination/$name"
  done
  for item in "$source/bin"/*; do
    [[ -e "$item" ]] || continue
    name="$(basename "$item")"
    [[ "$name" == cache ]] && continue
    if [[ -d "$item" ]]; then
      quotabot_link_or_copy "$item" "$destination/bin/$name"
    else
      cp "$item" "$destination/bin/$name"
      chmod +x "$destination/bin/$name" 2>/dev/null || true
    fi
  done
  for item in "$source/bin/cache"/*; do
    [[ -e "$item" ]] || continue
    name="$(basename "$item")"
    [[ "$name" == dart-sdk ]] && continue
    quotabot_link_or_copy "$item" "$destination/bin/cache/$name"
  done
  kind="$(quotabot_mirror_dart_sdk "$source/bin/cache/dart-sdk" "$destination/bin/cache/dart-sdk")"
  printf '%s\n' "$kind"
}

quotabot_enable_space_safe_dart() {
  local preferred_root="${1:-}"
  local include_flutter=0
  local sdk parent mirror kind dart_bin flutter_root flutter_bin
  case "${2:-}" in
    flutter | --flutter) include_flutter=1 ;;
    '' ) ;;
    *)
      echo "Unknown space-safe toolchain option: $2" >&2
      return 1
      ;;
  esac
  if ! sdk="$(quotabot_resolve_dart_sdk)"; then
    command -v dart
    return 0
  fi
  QUOTABOT_SPACE_SAFE_PATH_BACKUP="$PATH"
  if [[ -n "${DART_SDK+x}" ]]; then
    QUOTABOT_SPACE_SAFE_DART_SDK_BACKUP="$DART_SDK"
  else
    QUOTABOT_SPACE_SAFE_DART_SDK_BACKUP=""
  fi
  if [[ -n "${FLUTTER_ROOT+x}" ]]; then
    QUOTABOT_SPACE_SAFE_FLUTTER_ROOT_BACKUP="$FLUTTER_ROOT"
  else
    QUOTABOT_SPACE_SAFE_FLUTTER_ROOT_BACKUP=""
  fi

  if [[ "$include_flutter" -eq 1 ]]; then
    flutter_root="$(quotabot_resolve_flutter_root)" || return 1
    if [[ "$flutter_root" != *' '* ]]; then
      export FLUTTER_ROOT="$flutter_root"
      export DART_SDK="$flutter_root/bin/cache/dart-sdk"
      PATH="$flutter_root/bin:$DART_SDK/bin:$PATH"
      export PATH
      printf '%s\n' "$DART_SDK/bin/dart"
      return 0
    fi
    parent="$(quotabot_space_free_parent "$preferred_root")" || return 1
    mirror="$parent/flutter-sdk-$(date -u +%Y%m%d%H%M%S)-$$"
    kind="$(quotabot_mirror_flutter_sdk "$flutter_root" "$mirror")"
    dart_bin="$mirror/bin/cache/dart-sdk/bin/dart"
    flutter_bin="$mirror/bin/flutter"
    if [[ ! -x "$dart_bin" || ! -f "$flutter_bin" ]] ||
       ! quotabot_flutter_present "$mirror"; then
      rm -rf -- "$mirror"
      echo "Mapped Flutter SDK is incomplete: $mirror" >&2
      return 1
    fi
    QUOTABOT_SPACE_SAFE_MIRROR="$mirror"
    export FLUTTER_ROOT="$mirror"
    export DART_SDK="$mirror/bin/cache/dart-sdk"
    PATH="$mirror/bin:$DART_SDK/bin:$PATH"
    export PATH
    echo "Using space-free Flutter path $mirror ($kind) because the toolchain path contains spaces." >&2
    printf '%s\n' "$dart_bin"
    return 0
  fi

  if [[ "$sdk" != *' '* ]]; then
    export DART_SDK="$sdk"
    PATH="$sdk/bin:$PATH"
    export PATH
    printf '%s\n' "$sdk/bin/dart"
    return 0
  fi
  parent="$(quotabot_space_free_parent "$preferred_root")" || return 1
  mirror="$parent/dart-sdk-$(date -u +%Y%m%d%H%M%S)-$$"
  kind="$(quotabot_mirror_dart_sdk "$sdk" "$mirror")"
  dart_bin="$mirror/bin/dart"
  if [[ ! -x "$dart_bin" ]]; then
    rm -rf -- "$mirror"
    echo "Mapped Dart SDK is missing bin/dart: $dart_bin" >&2
    return 1
  fi
  QUOTABOT_SPACE_SAFE_MIRROR="$mirror"
  export DART_SDK="$mirror"
  PATH="$mirror/bin:$PATH"
  export PATH
  echo "Using space-free Dart path $dart_bin ($kind) because the toolchain path contains spaces." >&2
  printf '%s\n' "$dart_bin"
}
