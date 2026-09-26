#!/usr/bin/env bash
# Notarize and staple the app first, then rebuild/notarize/staple its DMG.
# Credentials must live in an `xcrun notarytool store-credentials` Keychain
# profile; this script never accepts Apple ID passwords as command arguments.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$REPO_ROOT/dist/swift/Click-n-speak.app}"
NOTARY_PROFILE="${CNS_NOTARY_PROFILE:-}"
TEAM_ID="${APPLE_TEAM_ID:-}"
ARCHITECTURE="${CNS_RELEASE_ARCHITECTURE:-$(uname -m)}"
TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/click-n-speak-notary.XXXXXX")"
cleanup() { rm -rf "$TEMPORARY_DIRECTORY"; }
trap cleanup EXIT

[ -d "$APP" ] || { echo "Application not found: $APP" >&2; exit 1; }
[ -n "$NOTARY_PROFILE" ] || {
    echo "Set CNS_NOTARY_PROFILE to a Keychain profile created by notarytool store-credentials." >&2
    exit 1
}
[ -n "$TEAM_ID" ] || { echo "Set APPLE_TEAM_ID for identity verification." >&2; exit 1; }

CNS_PRODUCTION_RELEASE=1 APPLE_TEAM_ID="$TEAM_ID" \
    "$REPO_ROOT/scripts/swift_verify_bundle.sh" "$APP"

APP_ARCHIVE="$TEMPORARY_DIRECTORY/Click-n-speak.zip"
ditto -c -k --keepParent "$APP" "$APP_ARCHIVE"
echo "==> Submitting signed application"
xcrun notarytool submit "$APP_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Rebuilding DMG with the stapled application"
CNS_PRODUCTION_RELEASE=1 APPLE_TEAM_ID="$TEAM_ID" \
    "$REPO_ROOT/scripts/make_swift_dmg.sh" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$REPO_ROOT/dist/Click-n-speak-$VERSION-$ARCHITECTURE.dmg"

echo "==> Submitting signed DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Stapling changes the DMG bytes, so regenerate trusted release metadata last.
CNS_PRODUCTION_RELEASE=1 APPLE_TEAM_ID="$TEAM_ID" \
    "$REPO_ROOT/scripts/generate_release_manifest.sh" "$APP" "$DMG"
echo "==> Notarization and offline acceptance checks passed"
