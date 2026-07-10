#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_base="${TMPDIR:-/tmp}"
root="$(mktemp -d "$temp_base/quotabot-desktop-test.XXXXXX")"
cleanup() {
  case "$root" in
    "$temp_base"/quotabot-desktop-test.*) rm -rf "$root" ;;
    *) echo "Refusing to remove unexpected test path: $root" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT

executable="$root/path with spaces/quotabot"
destination="$root/desktop entries/quotabot.desktop"
mkdir -p "$(dirname "$executable")"
touch "$executable"
chmod +x "$executable"

bash "$script_dir/write-desktop-entry.sh" \
  "$script_dir/quotabot.desktop" "$executable" "$destination"

expected="Exec=\"$executable\""
actual="$(grep '^Exec=' "$destination")"
[[ "$actual" == "$expected" ]] || {
  echo "Unexpected desktop Exec line: $actual" >&2
  exit 1
}
[[ "$(grep -c '^Exec=' "$destination")" -eq 1 ]]

for unsupported in '\' '"' '`' '$' '%' '=' $'\t'; do
  rejected="$root/rejected${unsupported}path/quotabot"
  if bash "$script_dir/write-desktop-entry.sh" \
      "$script_dir/quotabot.desktop" "$rejected" "$root/rejected.desktop" 2>/dev/null; then
    echo "Unsupported desktop path was accepted: $rejected" >&2
    exit 1
  fi
done

echo 'Linux desktop entry tests passed.'
