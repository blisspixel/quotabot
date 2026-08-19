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
  local parent
  if [[ -n "$preferred_root" && "$preferred_root" != *' '* ]]; then
    parent="$preferred_root/.setup-cache"
    mkdir -p "$parent" || true
    if [[ -d "$parent" ]]; then
      printf '%s\n' "$parent"
      return 0
    fi
  fi
  parent="${TMPDIR:-/tmp}/quotabot-build"
  mkdir -p "$parent" || true
  if [[ -d "$parent" && "$parent" != *' '* ]]; then
    printf '%s\n' "$parent"
    return 0
  fi
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

quotabot_enable_space_safe_dart() {
  local preferred_root="${1:-}"
  local sdk parent mirror kind dart_bin
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
