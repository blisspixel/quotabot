#!/usr/bin/env bash
# Build the quotabot Linux desktop release bundle and optionally archive it.

set -euo pipefail

archive=1
for arg in "$@"; do
  case "$arg" in
    --no-archive) archive=0 ;;
    -h | --help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
app_dir="$root/app"
release_dir="$root/release"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH. Install Flutter and add it to PATH." >&2
  exit 1
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  linux*) ;;
  *) echo "Linux desktop packaging must run on Linux, got: $os" >&2; exit 1 ;;
esac

arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) arch="x64" ;;
  arm64 | aarch64) arch="arm64" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

flutter config --enable-linux-desktop >/dev/null
(cd "$app_dir" && flutter build linux --release)

bundle="$app_dir/build/linux/$arch/release/bundle"
binary="$bundle/quotabot"
desktop="$root/tools/quotabot.desktop"
icon="$root/tools/quotabot.png"

if [ ! -x "$binary" ]; then
  echo "Build did not produce executable bundle: $binary" >&2
  exit 1
fi
if [ ! -f "$desktop" ]; then
  echo "Missing desktop entry template: $desktop" >&2
  exit 1
fi
if [ ! -f "$icon" ]; then
  echo "Missing Linux icon asset: $icon" >&2
  exit 1
fi

echo "Linux release bundle ready: $bundle"
echo "Desktop entry template: $desktop"
echo "Icon asset: $icon"

if [ "$archive" -eq 1 ]; then
  mkdir -p "$release_dir"
  out="$release_dir/quotabot-linux-$arch-desktop.tar.gz"
  asset="$(basename "$out")"
  rm -f "$out" "$out.sha256"
  tar -C "$bundle" -czf "$out" .
  hash="$(sha256sum "$out" | awk '{print tolower($1)}')"
  printf '%s  %s' "$hash" "$asset" > "$out.sha256"
  echo "Archive ready: $out"
  echo "Checksum: $out.sha256"
  echo "SHA256: $hash"
fi
