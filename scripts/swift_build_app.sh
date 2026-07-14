#!/usr/bin/env bash
# Build the Swift Click-n-speak.app bundle from the SPM executable.
#
# Phase 1: assembles a launchable menu-bar .app (binary + Info.plist + locales +
# icons). Code signing / notarization are added in Phase 8. Run from repo root:
#   ./scripts/swift_build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PKG="$REPO_ROOT/ClickNSpeak"
BUILD_DIR="$REPO_ROOT/dist/swift"
APP="$BUILD_DIR/Click-n-speak.app"

echo "==> Building ClickNSpeak ($CONFIG)"
( cd "$APP_PKG" && swift build -c "$CONFIG" )
BIN="$APP_PKG/.build/$CONFIG/ClickNSpeak"
[ -f "$BIN" ] || { echo "Binary not found: $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ClickNSpeak"
cp "$APP_PKG/Info.plist" "$APP/Contents/Info.plist"

# Bundled resources loaded at runtime by AppResources.resolve().
cp -R "$REPO_ROOT/locales" "$APP/Contents/Resources/locales"
cp -R "$REPO_ROOT/assets/icons" "$APP/Contents/Resources/icons"
if [ -f "$REPO_ROOT/assets/CnS.png" ]; then
    cp "$REPO_ROOT/assets/CnS.png" "$APP/Contents/Resources/CnS.png"
fi

# Ad-hoc sign so the menu-bar app launches locally without Gatekeeper prompts.
# Phase 8 replaces this with a Developer ID signature + notarization.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "   (ad-hoc codesign skipped/failed — app still launchable locally)"

echo "==> Built $APP"
du -sh "$APP"
