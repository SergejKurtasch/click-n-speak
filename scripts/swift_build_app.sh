#!/usr/bin/env bash
# Build, assemble, sign, and verify the Swift Click-n-speak application.
set -euo pipefail

CONFIG="${1:-release}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PACKAGE="$REPO_ROOT/ClickNSpeak"
BUILD_DIRECTORY="$REPO_ROOT/dist/swift"
APP="$BUILD_DIRECTORY/Click-n-speak.app"
PRODUCTION_RELEASE="${CNS_PRODUCTION_RELEASE:-0}"
SIGNING_IDENTITY="${CNS_CODESIGN_IDENTITY:-${APPLE_DEVELOPER_ID:-}}"
EXPECTED_TEAM_ID="${APPLE_TEAM_ID:-}"
RESET_TCC_AFTER_BUILD="${CNS_RESET_TCC_AFTER_BUILD:-1}"

if [ "$CONFIG" != "debug" ] && [ "$CONFIG" != "release" ]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 2
fi
if [ "$PRODUCTION_RELEASE" = "1" ]; then
    if [ "$CONFIG" != "release" ] || [ -z "$SIGNING_IDENTITY" ] || [ -z "$EXPECTED_TEAM_ID" ]; then
        echo "Production release requires release config, CNS_CODESIGN_IDENTITY, and APPLE_TEAM_ID." >&2
        exit 1
    fi
fi
if [ "$RESET_TCC_AFTER_BUILD" != "0" ] && [ "$RESET_TCC_AFTER_BUILD" != "1" ]; then
    echo "CNS_RESET_TCC_AFTER_BUILD must be 0 or 1." >&2
    exit 2
fi

echo "==> Building ClickNSpeak and CNSUpdateHelper ($CONFIG)"
( cd "$APP_PACKAGE" && swift build -c "$CONFIG" --product ClickNSpeak )
( cd "$APP_PACKAGE" && swift build -c "$CONFIG" --product CNSUpdateHelper )
MAIN_BINARY="$APP_PACKAGE/.build/$CONFIG/ClickNSpeak"
HELPER_BINARY="$APP_PACKAGE/.build/$CONFIG/CNSUpdateHelper"
for binary in "$MAIN_BINARY" "$HELPER_BINARY"; do
    [ -f "$binary" ] || { echo "Binary not found: $binary" >&2; exit 1; }
done

MLX_SWIFT_VERSION="0.31.4"
MLX_CHECKOUT="$APP_PACKAGE/.build/checkouts/mlx-swift"
MLX_METALLIB_CACHE="$BUILD_DIRECTORY/support/mlx-swift-$MLX_SWIFT_VERSION/mlx.metallib"
"$REPO_ROOT/scripts/build_mlx_metallib.sh" "$MLX_CHECKOUT" "$MLX_METALLIB_CACHE"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 0755 "$MAIN_BINARY" "$APP/Contents/MacOS/ClickNSpeak"
install -m 0755 "$HELPER_BINARY" "$APP/Contents/MacOS/CNSUpdateHelper"
install -m 0644 "$MLX_METALLIB_CACHE" "$APP/Contents/MacOS/mlx.metallib"
install -m 0644 "$APP_PACKAGE/Info.plist" "$APP/Contents/Info.plist"
cp -R "$REPO_ROOT/locales" "$APP/Contents/Resources/locales"
cp -R "$REPO_ROOT/assets/icons" "$APP/Contents/Resources/icons"
if [ -f "$REPO_ROOT/assets/CnS.png" ]; then
    install -m 0644 "$REPO_ROOT/assets/CnS.png" "$APP/Contents/Resources/CnS.png"
fi
install -m 0644 "$REPO_ROOT/assets/icon.icns" "$APP/Contents/Resources/icon.icns"

ENTITLEMENTS="$REPO_ROOT/ClickNSpeak/ClickNSpeak.entitlements"
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Signing nested executables and application with Developer ID"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$APP/Contents/MacOS/mlx.metallib"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP/Contents/MacOS/CNSUpdateHelper"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/ClickNSpeak"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" "$APP"
else
    if [ "$PRODUCTION_RELEASE" = "1" ]; then
        echo "Ad-hoc signing is forbidden for production releases." >&2
        exit 1
    fi
    echo "==> Ad-hoc signing development bundle"
    codesign --force --sign - "$APP/Contents/MacOS/mlx.metallib"
    codesign --force --sign - "$APP/Contents/MacOS/CNSUpdateHelper"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/ClickNSpeak"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
fi

APPLE_TEAM_ID="$EXPECTED_TEAM_ID" CNS_PRODUCTION_RELEASE="$PRODUCTION_RELEASE" \
    "$REPO_ROOT/scripts/swift_verify_bundle.sh" "$APP"

if [ "$PRODUCTION_RELEASE" = "1" ]; then
    echo "==> Preserving TCC permissions for the production release"
elif [ "$RESET_TCC_AFTER_BUILD" = "1" ]; then
    echo "==> Resetting TCC permissions for the new development build"
    "$REPO_ROOT/scripts/swift_reset_permissions_for_testing.sh" --confirm-reset
else
    echo "==> Preserving TCC permissions by explicit opt-out (CNS_RESET_TCC_AFTER_BUILD=0)"
fi

echo "==> Built and verified $APP"
du -sh "$APP"
