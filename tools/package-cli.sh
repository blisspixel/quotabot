#!/usr/bin/env bash
# Builds the quotabot CLI release asset for the current macOS or Linux machine.
# Produces release/quotabot-<os>-<arch>.tar.gz and a matching .sha256 sidecar.

set -euo pipefail

archive=1
package_only=0
for arg in "$@"; do
  case "$arg" in
    --no-archive) archive=0 ;;
    --package-only) package_only=1 ;;
    -h | --help)
      printf '%s\n' \
        'Usage: bash tools/package-cli.sh [--no-archive | --package-only]' \
        '  --no-archive  build and normalize the CLI bundle without packaging' \
        '  --package-only package the existing normalized bundle without building'
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$archive" -eq 0 ] && [ "$package_only" -eq 1 ]; then
  echo "--no-archive and --package-only cannot be combined." >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
collector_dir="$root/collector"
release_dir="$root/release"
build_dir="$collector_dir/build/quotabot_cli_release"
. "$script_dir/package-pair.sh"

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

asset="quotabot-${os}-${arch}.tar.gz"
out="$release_dir/$asset"
bundle="$build_dir/bundle"
packaged_executable="$bundle/bin/quotabot"

if [ "$package_only" -eq 0 ]; then
  if ! command -v dart >/dev/null 2>&1; then
    echo "dart not found on PATH. Install Flutter or Dart and add it to PATH." >&2
    exit 1
  fi

  # shellcheck source=posix-space-safe-dart.sh
  . "$script_dir/posix-space-safe-dart.sh"
  cleanup_space_safe_dart() { quotabot_restore_space_safe_dart; }
  trap cleanup_space_safe_dart EXIT
  quotabot_enable_space_safe_dart "$root" >/dev/null

  rm -rf "$build_dir"
  (cd "$collector_dir" && \
    dart pub get --enforce-lockfile && \
    dart build cli --target=bin/collect.dart --output="$build_dir")
  if [ ! -f "$bundle/bin/collect" ]; then
    echo "CLI build did not produce $bundle/bin/collect" >&2
    exit 1
  fi
  mv "$bundle/bin/collect" "$packaged_executable"
  trap - EXIT
  quotabot_restore_space_safe_dart
fi

if [ ! -x "$packaged_executable" ]; then
  if [ "$package_only" -eq 1 ]; then
    echo "Package-only mode requires the existing normalized CLI executable: $packaged_executable" >&2
  else
    echo "CLI build did not produce $packaged_executable" >&2
  fi
  exit 1
fi

if [ "$archive" -eq 0 ]; then
  echo "CLI bundle ready: $bundle"
  exit 0
fi

mkdir -p "$release_dir"
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
tar -C "$bundle" -czf "$temporary_out" .

if command -v sha256sum >/dev/null 2>&1; then
  hash="$(sha256sum "$temporary_out" | awk '{print tolower($1)}')"
else
  hash="$(shasum -a 256 "$temporary_out" | awk '{print tolower($1)}')"
fi
printf '%s  %s' "$hash" "$asset" > "$temporary_sidecar"

# Activate both complete files as one rollback-protected package pair.
publish_package_pair \
  "$temporary_out" "$temporary_sidecar" "$out" "$out.sha256" \
  "$package_workspace"
trap - EXIT
rm -rf "$package_workspace"

echo "CLI asset ready: $out"
echo "Checksum: $out.sha256"
echo "SHA256: $hash"
