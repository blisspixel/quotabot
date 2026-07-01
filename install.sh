#!/usr/bin/env bash
#
# One-command installer for quotabot CLI (macOS and Linux)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
#   QUOTABOT_REPO=owner/quotabot curl -fsSL https://raw.githubusercontent.com/owner/quotabot/main/install.sh | bash
#

set -euo pipefail

REPO="${QUOTABOT_REPO:-blisspixel/quotabot}"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_ROOT="${HOME}/.local/share/quotabot"
BINARY_NAME="quotabot"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid QUOTABOT_REPO value. Expected owner/repo." >&2
  exit 1
fi

echo "Installing quotabot CLI..."

# Create destination
mkdir -p "$INSTALL_DIR"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  darwin*)  OS="darwin" ;;
  linux*)   OS="linux" ;;
  *)        echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64 | amd64) ARCH="x64" ;;
  arm64 | aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Intel macOS has no prebuilt binary (GitHub retired the Intel runner and Intel
# Macs are past end of life). Point those users at the from-source build instead
# of failing on a 404.
if [[ "$OS" == "darwin" && "$ARCH" == "x64" ]]; then
  echo "No prebuilt CLI for Intel macOS. Build from source instead:" >&2
  echo "  git clone https://github.com/${REPO}.git" >&2
  echo "  cd quotabot && bash tools/setup.sh --cli-only" >&2
  exit 1
fi

ASSET="quotabot-${OS}-${ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

echo "Downloading ${ASSET}..."

tmpfile=$(mktemp)
checksum_file=$(mktemp)
extract_dir=$(mktemp -d)
cleanup() {
  rm -f "$tmpfile" "$checksum_file"
  rm -rf "$extract_dir"
}
trap cleanup EXIT

curl -fsSL "$URL" -o "$tmpfile"
if curl -fsSL "${URL}.sha256" -o "$checksum_file"; then
  expected=$(awk 'NR==1 {print tolower($1)}' "$checksum_file")
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Invalid checksum file for ${ASSET}" >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmpfile" | awk '{print tolower($1)}')
  else
    actual=$(shasum -a 256 "$tmpfile" | awk '{print tolower($1)}')
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for ${ASSET}" >&2
    exit 1
  fi
else
  echo "No checksum asset found at ${URL}.sha256; continuing with HTTPS verification only."
fi
tar -xzf "$tmpfile" -C "$extract_dir"
if [[ ! -x "$extract_dir/bin/quotabot" ]]; then
  echo "Downloaded archive did not contain executable bin/quotabot" >&2
  exit 1
fi
if [[ ! -d "$extract_dir/lib" ]]; then
  echo "Downloaded archive did not contain lib/" >&2
  exit 1
fi
rm -rf "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"
cp -R "$extract_dir/bin" "$extract_dir/lib" "$INSTALL_ROOT/"
cat > "$INSTALL_DIR/$BINARY_NAME" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_ROOT/bin/quotabot" "\$@"
EOF
chmod +x "$INSTALL_DIR/$BINARY_NAME"

# PATH check
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "NOTE: $INSTALL_DIR is not in your PATH."
  echo "Add this line to your shell profile (~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish, etc.):"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
  echo "Then run:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "quotabot installed to $INSTALL_ROOT"
echo ""
echo "Next steps:"
echo "  quotabot doctor"
echo "  quotabot login grok"
echo "  quotabot login antigravity  # optional, keeps Antigravity live"
echo ""
echo "Re-run this script anytime to update."
