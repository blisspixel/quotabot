#!/usr/bin/env bash
# Simple Linux packaging notes + helper for quotabot.
# Run on a Linux machine with Flutter desktop enabled.
# Builds release. For AppImage preferred portable: use appimagetool on bundle.
# For deb: use platform tools or dpkg after bundle.
# Include .desktop file for menu integration.

set -e
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"

echo "On Linux target:"
echo "  flutter config --enable-linux-desktop"
echo "  cd app"
echo "  flutter build linux --release"
echo ""
echo "Output: app/build/linux/x64/release/bundle/quotabot (or similar)"
echo "  - Copy the bundle for portable."
echo "  - Install icon: cp tools/quotabot.png /usr/share/icons/hicolor/256x256/apps/quotabot.png"
echo "  - For .desktop (copy tools/quotabot.desktop to /usr/share/applications/):"
cat "$root/tools/quotabot.desktop"
echo ""
echo ""
echo "AppImage example: appimagetool bundle/ quotabot.AppImage"
echo "Test on target distro. See README for full 2026 notes."
