#!/usr/bin/env bash
# Builds the quotabot CLI release asset for the current macOS or Linux machine.
# Produces release/quotabot-<os>-<arch> and a matching .sha256 sidecar.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
collector_dir="$root/collector"
release_dir="$root/release"

if ! command -v dart >/dev/null 2>&1; then
  echo "dart not found on PATH. Install Flutter or Dart and add it to PATH." >&2
  exit 1
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
  darwin*) os="darwin" ;;
  linux*) os="linux" ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac

case "$arch" in
  x86_64 | amd64) arch="x64" ;;
  arm64 | aarch64) arch="arm64" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

mkdir -p "$release_dir"
asset="quotabot-${os}-${arch}"
out="$release_dir/$asset"

(cd "$collector_dir" && dart compile exe bin/collect.dart -o "$out")

if command -v sha256sum >/dev/null 2>&1; then
  hash="$(sha256sum "$out" | awk '{print tolower($1)}')"
else
  hash="$(shasum -a 256 "$out" | awk '{print tolower($1)}')"
fi
printf '%s  %s' "$hash" "$asset" > "$out.sha256"

echo "CLI asset ready: $out"
echo "Checksum: $out.sha256"
echo "SHA256: $hash"
