#!/usr/bin/env bash
# Build the quotabot macOS desktop release bundle and optionally archive it.

set -euo pipefail

archive=1
for arg in "$@"; do
  case "$arg" in
    --no-archive) archive=0 ;;
    -h | --help)
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
app_dir="$root/app"
release_dir="$root/release"
. "$script_dir/package-pair.sh"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH. Install Flutter and add it to PATH." >&2
  exit 1
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  darwin*) ;;
  *) echo "macOS desktop packaging must run on macOS, got: $os" >&2; exit 1 ;;
esac

arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) arch="x64" ;;
  arm64 | aarch64) arch="arm64" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

flutter config --enable-macos-desktop >/dev/null
(cd "$app_dir" && flutter build macos --release)

app_bundle="$app_dir/build/macos/Build/Products/Release/quotabot.app"
binary="$app_bundle/Contents/MacOS/quotabot"
if [ ! -x "$binary" ]; then
  echo "Build did not produce app bundle executable: $binary" >&2
  exit 1
fi

echo "macOS release bundle ready: $app_bundle"
echo "Production distribution still requires Developer ID signing, notarization, and stapling."

if [ "$archive" -eq 1 ]; then
  mkdir -p "$release_dir"
  out="$release_dir/quotabot-darwin-$arch-desktop.zip"
  asset="$(basename "$out")"
  package_workspace="$(mktemp -d "$release_dir/.quotabot-package.XXXXXX")"
  cleanup_package() {
    if [[ -e "$package_workspace/.preserve" ]]; then
      echo "Package recovery files were preserved in $package_workspace" >&2
    else
      rm -rf "$package_workspace"
    fi
  }
  trap cleanup_package EXIT
  temporary_out="$package_workspace/$asset"
  temporary_sidecar="$package_workspace/$asset.sha256"
  ditto -c -k --keepParent "$app_bundle" "$temporary_out"
  hash="$(shasum -a 256 "$temporary_out" | awk '{print tolower($1)}')"
  printf '%s  %s' "$hash" "$asset" > "$temporary_sidecar"

  # Activate both complete files as one rollback-protected package pair.
  publish_package_pair \
    "$temporary_out" "$temporary_sidecar" "$out" "$out.sha256" \
    "$package_workspace"
  trap - EXIT
  rm -rf "$package_workspace"
  echo "Archive ready: $out"
  echo "Checksum: $out.sha256"
  echo "SHA256: $hash"
fi
