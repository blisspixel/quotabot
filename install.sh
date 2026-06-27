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

ASSET="quotabot-${OS}-${ARCH}"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

echo "Downloading ${ASSET}..."

tmpfile=$(mktemp)
checksum_file=$(mktemp)
cleanup() {
  rm -f "$tmpfile" "$checksum_file"
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
chmod +x "$tmpfile"
mv "$tmpfile" "$INSTALL_DIR/$BINARY_NAME"

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
echo "quotabot installed to $INSTALL_DIR/$BINARY_NAME"
echo ""
echo "Next steps:"
echo "  quotabot doctor"
echo "  quotabot login grok"
echo "  # Optional Antigravity persistent login requires QUOTABOT_GOOGLE_CLIENT_ID/SECRET"
echo ""
echo "Re-run this script anytime to update."
