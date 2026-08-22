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

spaced_root="$fixture_root/repo with spaces"
mkdir -p -- "$spaced_root"
HOME_BACKUP="${HOME-}"
XDG_BACKUP="${XDG_CACHE_HOME-}"
TMPDIR_BACKUP="${TMPDIR-}"
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/xdg-cache"
unset TMPDIR
mkdir -p -- "$HOME" "$XDG_CACHE_HOME"
user_parent="$(quotabot_space_free_parent "$spaced_root")"
if [[ "$user_parent" != "$XDG_CACHE_HOME/quotabot-build" ]]; then
  echo "Spaced checkout did not use the user cache parent: $user_parent" >&2
  exit 1
fi
if [[ "$HOME_BACKUP" ]]; then
  export HOME="$HOME_BACKUP"
else
  unset HOME
fi
if [[ "${XDG_BACKUP+x}" ]]; then
  export XDG_CACHE_HOME="$XDG_BACKUP"
else
  unset XDG_CACHE_HOME
fi
if [[ "${TMPDIR_BACKUP+x}" ]]; then
  export TMPDIR="$TMPDIR_BACKUP"
fi

flutter_src="$fixture_root/flutter with spaces"
mkdir -p "$flutter_src/bin/cache/dart-sdk/bin"
mkdir -p "$flutter_src/packages/flutter_tools/.dart_tool"
printf 'sdk\n' > "$flutter_src/bin/cache/dart-sdk/bin/dart"
chmod +x "$flutter_src/bin/cache/dart-sdk/bin/dart"
printf 'snapshot\n' > "$flutter_src/bin/cache/flutter_tools.snapshot"
printf '{}\n' > "$flutter_src/packages/flutter_tools/.dart_tool/package_config.json"
printf 'engine\n' > "$flutter_src/bin/cache/engine.stamp"
printf '%s\n' '#!/bin/sh' 'echo flutter' > "$flutter_src/bin/flutter"
chmod +x "$flutter_src/bin/flutter"

flutter_mirror="$fixture_root/flutter-mirror"
kind="$(quotabot_mirror_flutter_sdk "$flutter_src" "$flutter_mirror")"
case "$kind" in
  hardlink | copy) ;;
  *)
    echo "Unexpected Flutter mirror kind: $kind" >&2
    exit 1
    ;;
esac
if [[ "$flutter_mirror" == *' '* ]]; then
  echo "Flutter mirror path still contains spaces: $flutter_mirror" >&2
  exit 1
fi
if ! quotabot_flutter_present "$flutter_mirror"; then
  echo "Mapped Flutter SDK is incomplete: $flutter_mirror" >&2
  exit 1
fi
if [[ -L "$flutter_mirror/bin/flutter" ]]; then
  echo "Flutter launcher was symlinked; pwd -P would recover the spaced path." >&2
  exit 1
fi
if [[ ! -f "$flutter_mirror/bin/flutter" ]]; then
  echo "Mapped Flutter launcher is missing: $flutter_mirror/bin/flutter" >&2
  exit 1
fi
dart_content="$(cat "$flutter_mirror/bin/cache/dart-sdk/bin/dart")"
if [[ "$dart_content" != $'sdk\n' && "$dart_content" != sdk ]]; then
  echo "Mapped Flutter dart-sdk content did not match." >&2
  exit 1
fi
if [[ ! -e "$flutter_mirror/bin/cache/engine.stamp" ]]; then
  echo "Mapped Flutter cache entries were not linked." >&2
  exit 1
fi

if quotabot_enable_space_safe_dart "$script_dir/.." 'not-a-mode'; then
  echo 'Unknown space-safe toolchain option was accepted.' >&2
  exit 1
fi

echo 'POSIX space-safe Dart helper tests passed.'
