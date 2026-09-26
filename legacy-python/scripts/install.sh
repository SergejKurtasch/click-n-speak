#!/bin/bash
# Install Click-n-speak to /Applications.
#
# Why /Applications?
#   macOS TCC (permissions database) tracks apps by path + bundle ID + signature.
#   Installing to a fixed path means permissions survive app updates — the OS
#   recognises it as the same app and does NOT ask again.
#
# Usage:
#   bash scripts/install.sh              # install after build
#   bash scripts/install.sh --build      # build first, then install
#
set -e

APP_NAME="Click-n-speak"
SOURCE="$(cd "$(dirname "$0")/.." && pwd)/dist/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optionally build first
if [[ "$1" == "--build" ]]; then
    echo "=== Building ${APP_NAME}... ==="
    bash "${SCRIPT_DIR}/build_launcher.sh"
fi

# Verify the built bundle exists
if [ ! -d "${SOURCE}" ]; then
    echo "ERROR: ${SOURCE} not found."
    echo "Run 'bash scripts/build_launcher.sh' first, or use --build flag."
    exit 1
fi

echo "=== Installing ${APP_NAME} to /Applications ==="

# Stop the running app if it is open (graceful quit via osascript)
if pgrep -x "${APP_NAME}" > /dev/null 2>&1; then
    echo "  Quitting running instance..."
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    sleep 1
fi

# Remove old installation (strip Sequoia provenance xattr first)
if [ -d "${DEST}" ]; then
    echo "  Removing old installation..."
    xattr -r -d com.apple.provenance "${DEST}" 2>/dev/null || true
    chmod -R u+w "${DEST}" 2>/dev/null || true
    rm -rf "${DEST}"
fi

# Copy new bundle
echo "  Copying ${APP_NAME}.app to /Applications..."
cp -R "${SOURCE}" "${DEST}"

# Re-sign with ad-hoc identity (preserves TCC entry for the bundle ID)
echo "  Signing bundle..."
codesign --force --deep --sign - "${DEST}" 2>/dev/null \
    && echo "  Bundle signed successfully." \
    || echo "  Warning: codesign failed (non-critical for local use)."

echo ""
echo "✅ Installation complete: ${DEST}"
echo "   Size: $(du -sh "${DEST}" | cut -f1)"
echo ""
echo "To launch: open ${DEST}"
echo ""
echo "Important: The app is now installed at a fixed path."
echo "Future updates via this script will preserve your permissions"
echo "(Microphone, Accessibility) without asking again."
