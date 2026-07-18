#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/package-pair.sh"

temp_base="${TMPDIR:-/tmp}"
test_root="$(mktemp -d "$temp_base/quotabot-package-pair.XXXXXX")"
cleanup() {
  case "$test_root" in
    "$temp_base"/quotabot-package-pair.*) rm -rf "$test_root" ;;
    *) echo "Refusing to remove unexpected test path: $test_root" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT

workspace="$test_root/workspace"
archive="$test_root/quotabot.tar.gz"
sidecar="$archive.sha256"
temporary_archive="$workspace/quotabot.tar.gz"
temporary_sidecar="$temporary_archive.sha256"
mkdir -p "$workspace"
printf 'old archive' > "$archive"
printf 'old checksum' > "$sidecar"
printf 'new archive' > "$temporary_archive"
printf 'new checksum' > "$temporary_sidecar"

export temporary_sidecar sidecar
injection_marker="$test_root/injected"
export injection_marker
set +e
bash -c '
  set -euo pipefail
  . "$1"
  real_mv="$(command -v mv)"
  mv() {
    if [[ "$1" == "$temporary_sidecar" && "$2" == "$sidecar" ]]; then
      : > "$injection_marker"
      return 73
    fi
    "$real_mv" "$@"
  }
  publish_package_pair "$2" "$3" "$4" "$5" "$6"
' _ "$script_dir/package-pair.sh" \
  "$temporary_archive" "$temporary_sidecar" "$archive" "$sidecar" "$workspace"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  echo 'The injected checksum activation failure was not surfaced.' >&2
  exit 1
}
[[ -f "$injection_marker" ]] || {
  echo 'The checksum activation failure was not the cause of the failed transaction.' >&2
  exit 1
}
[[ "$(cat "$archive")" == 'old archive' ]]
[[ "$(cat "$sidecar")" == 'old checksum' ]]
[[ ! -e "$archive.quotabot-package.lock" && ! -L "$archive.quotabot-package.lock" ]]

printf 'new archive' > "$temporary_archive"
printf 'new checksum' > "$temporary_sidecar"
lock_path="$archive.quotabot-package.lock"
printf '%s\n' "$$" > "$lock_path"
set +e
publish_package_pair \
  "$temporary_archive" "$temporary_sidecar" "$archive" "$sidecar" "$workspace"
lock_status=$?
set -e
[[ "$lock_status" -ne 0 ]] || {
  echo 'A concurrent package publisher was not rejected.' >&2
  exit 1
}
[[ "$(cat "$archive")" == 'old archive' ]]
[[ "$(cat "$sidecar")" == 'old checksum' ]]
[[ "$(cat "$lock_path")" == "$$" ]]
rm -f "$lock_path"

echo 'POSIX package pair transaction tests passed.'
