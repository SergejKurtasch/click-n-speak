#!/usr/bin/env bash
# Read-only acceptance checks for an assembled Swift application bundle.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$REPO_ROOT/dist/swift/Click-n-speak.app}"
EXPECTED_BUNDLE_ID="com.sergej.clicknspeak"
EXPECTED_TEAM_ID="${APPLE_TEAM_ID:-}"
PRODUCTION_RELEASE="${CNS_PRODUCTION_RELEASE:-0}"
EXPECTED_ARCHITECTURE="${CNS_RELEASE_ARCHITECTURE:-$(uname -m)}"

[ -d "$APP" ] || { echo "Application bundle not found: $APP" >&2; exit 1; }
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/ClickNSpeak"
HELPER="$APP/Contents/MacOS/CNSUpdateHelper"
MLX_METALLIB="$APP/Contents/MacOS/mlx.metallib"
LOCALES="$APP/Contents/Resources/locales"
ICONS="$APP/Contents/Resources/icons"
APP_ICON="$APP/Contents/Resources/icon.icns"

for required in "$PLIST" "$EXECUTABLE" "$HELPER" "$MLX_METALLIB" "$LOCALES" "$ICONS" "$APP_ICON"; do
    [ -e "$required" ] || { echo "Missing required bundle resource: $required" >&2; exit 1; }
done
[ -x "$EXECUTABLE" ] && [ -x "$HELPER" ] || {
    echo "Application executables do not have executable permissions." >&2
    exit 1
}

MLX_METALLIB_SIZE="$(stat -f '%z' "$MLX_METALLIB")"
[ "$MLX_METALLIB_SIZE" -ge 1000000 ] || {
    echo "MLX metallib is unexpectedly small: $MLX_METALLIB_SIZE bytes" >&2
    exit 1
}

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
[ "$ACTUAL_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || {
    echo "Unexpected bundle identifier: $ACTUAL_BUNDLE_ID" >&2
    exit 1
}
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" >/dev/null
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")"
[ "$ICON_NAME" = "icon" ] || {
    echo "Unexpected application icon declaration: $ICON_NAME" >&2
    exit 1
}

for signed_code in "$MLX_METALLIB" "$HELPER" "$EXECUTABLE" "$APP"; do
    codesign --verify --strict --verbose=2 "$signed_code"
done
codesign --verify --deep --strict --verbose=2 "$APP"

SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
echo "$SIGNATURE_DETAILS" | grep -q "Identifier=$EXPECTED_BUNDLE_ID"
echo "$SIGNATURE_DETAILS" | grep -q 'flags=.*runtime' || {
    if [ "$PRODUCTION_RELEASE" = "1" ]; then
        echo "Hardened runtime flag is missing." >&2
        exit 1
    fi
}
if [ -n "$EXPECTED_TEAM_ID" ]; then
    echo "$SIGNATURE_DETAILS" | grep -q "TeamIdentifier=$EXPECTED_TEAM_ID" || {
        echo "Unexpected signing Team ID." >&2
        exit 1
    }
elif [ "$PRODUCTION_RELEASE" = "1" ]; then
    echo "APPLE_TEAM_ID is required for production verification." >&2
    exit 1
fi

for binary in "$EXECUTABLE" "$HELPER"; do
    ARCHITECTURES="$(lipo -archs "$binary")"
    echo "$ARCHITECTURES" | tr ' ' '\n' | grep -qx "$EXPECTED_ARCHITECTURE" || {
        echo "Required architecture $EXPECTED_ARCHITECTURE missing from $binary" >&2
        exit 1
    }
done

for forbidden in \
    "$APP/Contents/Library/PrivilegedHelperTools" \
    "$APP/Contents/Library/LaunchDaemons" \
    "$APP/Contents/Library/SystemExtensions"; do
    [ ! -e "$forbidden" ] || { echo "Unexpected privileged payload: $forbidden" >&2; exit 1; }
done

if [ "$PRODUCTION_RELEASE" = "1" ] || [ "${CNS_REQUIRE_GATEKEEPER:-0}" = "1" ]; then
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo "Bundle verification passed: $APP"
