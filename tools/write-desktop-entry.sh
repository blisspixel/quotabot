#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 TEMPLATE EXECUTABLE DESTINATION" >&2
  exit 2
fi

template="$1"
executable="$2"
destination="$3"

[[ -f "$template" ]] || { echo "Desktop template not found: $template" >&2; exit 1; }
[[ -n "$executable" ]] || { echo 'Desktop executable path is empty.' >&2; exit 1; }
if [[ "$executable" == *$'\n'* || "$executable" == *$'\r'* ]]; then
  echo 'Desktop executable path contains a line break.' >&2
  exit 1
fi
if LC_ALL=C printf '%s' "$executable" | grep -q '[[:cntrl:]]'; then
  echo 'Desktop executable path contains a control character.' >&2
  exit 1
fi
# Desktop Entry parsing applies string unescaping before Exec tokenization.
# Reject the metacharacters that would require two distinct escape passes;
# common POSIX paths, including spaces, remain supported.
if [[ "$executable" == *'\'* || "$executable" == *'"'* ||
      "$executable" == *'`'* || "$executable" == *'$'* ||
      "$executable" == *'%'* || "$executable" == *'='* ]]; then
  echo 'Desktop executable path contains an unsupported Exec metacharacter.' >&2
  exit 1
fi

destination_dir="$(dirname "$destination")"
mkdir -p "$destination_dir"
temporary="$(mktemp "$destination_dir/.quotabot.desktop.XXXXXX")"
cleanup() {
  rm -f "$temporary"
}
trap cleanup EXIT

exec_lines=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == 'Exec=quotabot' ]]; then
    printf 'Exec="%s"\n' "$executable" >> "$temporary"
    exec_lines=$((exec_lines + 1))
  else
    printf '%s\n' "$line" >> "$temporary"
  fi
done < "$template"

if [[ $exec_lines -ne 1 ]]; then
  echo "Expected one Exec=quotabot line in $template; found $exec_lines." >&2
  exit 1
fi

chmod 0644 "$temporary"
mv -f "$temporary" "$destination"
trap - EXIT
