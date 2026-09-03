#!/usr/bin/env bash
# Generate trusted release metadata for an already signed/stapled DMG.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$REPO_ROOT/dist/swift/Click-n-speak.app}"
DMG="${2:-}"
TEAM_ID="${APPLE_TEAM_ID:-}"
CHANNEL="${CNS_RELEASE_CHANNEL:-stable}"
ARCHITECTURE="${CNS_RELEASE_ARCHITECTURE:-$(uname -m)}"

[ -d "$APP" ] || { echo "Application not found: $APP" >&2; exit 1; }
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
if [ -z "$DMG" ]; then
    DMG="$REPO_ROOT/dist/Click-n-speak-$VERSION-$ARCHITECTURE.dmg"
fi
[ -f "$DMG" ] || { echo "DMG not found: $DMG" >&2; exit 1; }
[ -n "$TEAM_ID" ] || { echo "APPLE_TEAM_ID is required." >&2; exit 1; }

MANIFEST="$REPO_ROOT/dist/Click-n-speak-$VERSION-$ARCHITECTURE.manifest.json"
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
DMG_SIZE="$(stat -f '%z' "$DMG")"
rm -f "$MANIFEST"
/usr/libexec/PlistBuddy -c 'Clear dict' "$MANIFEST"
/usr/libexec/PlistBuddy -c 'Add :schema_version integer 1' "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :version string $VERSION" "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :channel string $CHANNEL" "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :architecture string $ARCHITECTURE" "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :minimum_macos string $MINIMUM_MACOS" "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :bundle_id string $BUNDLE_ID" "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :team_id string $TEAM_ID" "$MANIFEST"
/usr/libexec/PlistBuddy -c 'Add :dmg dict' "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :dmg:file_name string $(basename "$DMG")" "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :dmg:sha256 string $DMG_SHA256" "$MANIFEST"
/usr/libexec/PlistBuddy -c "Add :dmg:size integer $DMG_SIZE" "$MANIFEST"
/usr/bin/plutil -convert json "$MANIFEST"
jq empty "$MANIFEST"
echo "==> Updated $MANIFEST"
