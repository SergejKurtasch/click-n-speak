#!/bin/bash
set -e

# Configuration
APP_NAME="Click-n-speak"
APP_BUNDLE="dist/${APP_NAME}.app"
DMG_NAME="dist/${APP_NAME}.dmg"
TMP_DIR="/tmp/dmg_build"

echo "🚀 Starting DMG creation for ${APP_NAME}..."

# 1. Check if the app exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ Error: ${APP_BUNDLE} not found. Running build script first..."
    bash scripts/build.sh
fi

# 2. Cleanup previous runs
rm -f "$DMG_NAME"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# 3. Copy app to temporary directory
echo "📦 Copying app to temporary folder..."
cp -R "$APP_BUNDLE" "$TMP_DIR/"

# 4. Create symlink to /Applications
echo "🔗 Creating symlink to /Applications..."
ln -s /Applications "$TMP_DIR/Applications"

# 5. Create the DMG
echo "💿 Creating DMG image (this may take a minute)..."
hdiutil create -volname "${APP_NAME}" -srcfolder "$TMP_DIR" -ov -format UDZO "$DMG_NAME"

# 6. Cleanup
rm -rf "$TMP_DIR"

echo "✅ Success! DMG created at: ${DMG_NAME}"
ls -lh "$DMG_NAME"
