#!/usr/bin/env bash
# Build the MLX default Metal library from the pinned mlx-swift checkout.
#
# mlx-swift 0.31.4 declares the SwiftPM bundle lookup but does not generate
# default.metallib during a command-line SwiftPM build. The upstream Xcode
# project is therefore the canonical source for this runtime resource.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <mlx-swift-checkout> <output-metallib>" >&2
    exit 2
fi

MLX_CHECKOUT="$1"
OUTPUT="$2"
PROJECT="$MLX_CHECKOUT/xcode/MLX.xcodeproj"

if [ ! -d "$PROJECT" ]; then
    echo "mlx-swift Xcode project not found: $PROJECT" >&2
    exit 1
fi

if ! xcrun -f metal >/dev/null 2>&1; then
    echo "Apple Metal Toolchain is required to build MLX kernels." >&2
    echo "Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

if [ -s "$OUTPUT" ]; then
    echo "==> Reusing cached MLX metallib: $OUTPUT"
    exit 0
fi

DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/cns-mlx-derived.XXXXXX")"
cleanup() {
    rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

echo "==> Building MLX Metal kernels from the pinned checkout"
xcodebuild \
    -project "$PROJECT" \
    -scheme Cmlx \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    -quiet \
    build

BUILT_METALLIB="$DERIVED_DATA/Build/Products/Release/Cmlx.framework/Versions/A/Resources/default.metallib"
if [ ! -s "$BUILT_METALLIB" ]; then
    echo "MLX build did not produce default.metallib" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$BUILT_METALLIB" "$OUTPUT"
echo "==> Built MLX metallib: $OUTPUT"
