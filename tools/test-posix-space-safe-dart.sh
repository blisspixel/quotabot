#!/usr/bin/env bash
# Exercises the POSIX space-free Dart mapping helper.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=posix-space-safe-dart.sh
. "$script_dir/posix-space-safe-dart.sh"

plain_parent="$script_dir"
if [[ "$plain_parent" == *' '* ]]; then
  echo 'The tools directory contains spaces; cannot test a verbatim parent.' >&2
  exit 1
fi

fixture_root="$plain_parent/posix-space-safe-fixture-$$"
cleanup() { rm -rf -- "$fixture_root"; }
trap cleanup EXIT
mkdir -p "$fixture_root/sdk with spaces/bin"
printf 'sdk\n' > "$fixture_root/sdk with spaces/bin/dart"
chmod +x "$fixture_root/sdk with spaces/bin/dart"

mirror="$fixture_root/mirror"
kind="$(quotabot_mirror_dart_sdk "$fixture_root/sdk with spaces" "$mirror")"
case "$kind" in
  hardlink | copy) ;;
  *)
    echo "Unexpected mirror kind: $kind" >&2
    exit 1
    ;;
esac
if [[ ! -e "$mirror/bin/dart" && ! -e "$mirror/bin/dart.exe" ]]; then
  echo "Mirrored dart is missing: $mirror/bin/dart" >&2
  exit 1
fi
if [[ "$mirror" == *' '* ]]; then
  echo "Mirror path still contains spaces: $mirror" >&2
  exit 1
fi
content="$(cat "$mirror/bin/dart")"
if [[ "$content" != $'sdk\n' && "$content" != sdk ]]; then
  echo "Mirrored dart content did not match." >&2
  exit 1
fi

parent="$(quotabot_space_free_parent "$script_dir/..")"
if [[ "$parent" == *' '* ]]; then
  echo "Space-free parent still contains spaces: $parent" >&2
  exit 1
fi

echo 'POSIX space-safe Dart helper tests passed.'
