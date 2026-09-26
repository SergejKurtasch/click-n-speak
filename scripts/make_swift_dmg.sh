#!/usr/bin/env bash
# Create, sign, verify, and describe the Swift release DMG.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$REPO_ROOT/dist/swift/Click-n-speak.app}"
DIST_DIRECTORY="$REPO_ROOT/dist"
PLIST="$APP/Contents/Info.plist"
PRODUCTION_RELEASE="${CNS_PRODUCTION_RELEASE:-0}"
SIGNING_IDENTITY="${CNS_CODESIGN_IDENTITY:-${APPLE_DEVELOPER_ID:-}}"
TEAM_ID="${APPLE_TEAM_ID:-}"
CHANNEL="${CNS_RELEASE_CHANNEL:-stable}"
ARCHITECTURE="${CNS_RELEASE_ARCHITECTURE:-$(uname -m)}"

[ -d "$APP" ] || { echo "App bundle not found: $APP" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
GIT_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
DMG_NAME="Click-n-speak-$VERSION-$ARCHITECTURE.dmg"
DMG_PATH="$DIST_DIRECTORY/$DMG_NAME"
MANIFEST_PATH="$DIST_DIRECTORY/Click-n-speak-$VERSION-$ARCHITECTURE.manifest.json"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/click-n-speak-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGING_DIRECTORY"; }
trap cleanup EXIT

if [ "$PRODUCTION_RELEASE" = "1" ] && { [ -z "$SIGNING_IDENTITY" ] || [ -z "$TEAM_ID" ]; }; then
    echo "Production DMG requires CNS_CODESIGN_IDENTITY and APPLE_TEAM_ID." >&2
    exit 1
fi

APPLE_TEAM_ID="$TEAM_ID" CNS_PRODUCTION_RELEASE="$PRODUCTION_RELEASE" \
    "$REPO_ROOT/scripts/swift_verify_bundle.sh" "$APP"

echo "==> Building $DMG_PATH"
cp -R "$APP" "$STAGING_DIRECTORY/"
ln -s /Applications "$STAGING_DIRECTORY/Applications"
rm -f "$DMG_PATH" "$MANIFEST_PATH"
hdiutil create -volname "Click-n-speak" -srcfolder "$STAGING_DIRECTORY" \
    -ov -format UDZO "$DMG_PATH"

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
elif [ "$PRODUCTION_RELEASE" = "1" ]; then
    echo "Unsigned DMGs are forbidden for production releases." >&2
    exit 1
fi

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_SIZE="$(stat -f '%z' "$DMG_PATH")"
/usr/libexec/PlistBuddy -c 'Clear dict' "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c 'Add :schema_version integer 1' "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :git_revision string $GIT_REVISION" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :version string $VERSION" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :channel string $CHANNEL" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :architecture string $ARCHITECTURE" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :minimum_macos string $MINIMUM_MACOS" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :bundle_id string $BUNDLE_ID" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :team_id string $TEAM_ID" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c 'Add :dmg dict' "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :dmg:file_name string $DMG_NAME" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :dmg:sha256 string $DMG_SHA256" "$MANIFEST_PATH"
/usr/libexec/PlistBuddy -c "Add :dmg:size integer $DMG_SIZE" "$MANIFEST_PATH"
/usr/bin/plutil -convert json "$MANIFEST_PATH"

jq empty "$MANIFEST_PATH"
echo "==> Created $DMG_PATH"
echo "==> Created $MANIFEST_PATH"
