#!/usr/bin/env bash
set -euo pipefail

expected_developer_dir='/Applications/Xcode_16.4.app/Contents/Developer'
expected_version=$'Xcode 16.4\nBuild version 16F6'

[[ "$(/usr/bin/uname -s)" == Darwin ]] || {
  echo 'The pinned Apple toolchain requires macOS.' >&2
  exit 1
}
[[ "$(/usr/bin/uname -m)" == arm64 ]] || {
  echo 'The pinned Apple toolchain requires an arm64 runner.' >&2
  exit 1
}
[[ "${DEVELOPER_DIR:-}" == "$expected_developer_dir" ]] || {
  echo 'DEVELOPER_DIR does not select the pinned Xcode toolchain.' >&2
  exit 1
}
[[ -d "$expected_developer_dir" ]] || {
  echo 'The pinned Xcode toolchain is unavailable.' >&2
  exit 1
}
[[ "$(/usr/bin/xcodebuild -version)" == "$expected_version" ]] || {
  echo 'The selected Xcode version or build is unexpected.' >&2
  exit 1
}
[[ -x /usr/bin/codesign && -x /usr/sbin/spctl && -x /usr/bin/xcrun ]] || {
  echo 'A required Apple security tool is unavailable.' >&2
  exit 1
}
for tool in notarytool stapler; do
  resolved="$(/usr/bin/xcrun --find "$tool")"
  [[ -n "$resolved" && -x "$resolved" ]] || {
    echo "The pinned Apple toolchain cannot resolve $tool." >&2
    exit 1
  }
done

printf 'Pinned Apple toolchain: Xcode 16.4 build 16F6 on arm64.\n'
