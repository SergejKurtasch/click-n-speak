#!/usr/bin/env bash
# Run only the real-model local Qwen editor suite for acceptance.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "${CNS_QWEN_MODEL_DIR:-}" ] || {
    echo "CNS_QWEN_MODEL_DIR is required" >&2
    exit 2
}
for name in config.json tokenizer.json model.safetensors; do
    [ -f "$CNS_QWEN_MODEL_DIR/$name" ] || {
        echo "CNS_QWEN_MODEL_DIR is incomplete" >&2
        exit 2
    }
done

EDITOR_PACKAGE="$REPO_ROOT/Packages/CNSEditors"
swift build -c release --build-tests --disable-index-store \
    --package-path "$EDITOR_PACKAGE" \
    -Xswiftc -enable-testing \
    -Xswiftc -DCNS_EDITOR_MODEL_TESTS
EDITOR_BIN_DIR="$(swift build -c release --show-bin-path --package-path "$EDITOR_PACKAGE")"
EDITOR_TEST_MACOS="$EDITOR_BIN_DIR/CNSEditorsPackageTests.xctest/Contents/MacOS"
[ -d "$EDITOR_TEST_MACOS" ] || {
    echo "CNSEditors test bundle not found" >&2
    exit 1
}
MLX_SWIFT_VERSION="0.31.4"
MLX_METALLIB_CACHE="$REPO_ROOT/dist/swift/support/mlx-swift-$MLX_SWIFT_VERSION/mlx.metallib"
"$REPO_ROOT/scripts/build_mlx_metallib.sh" \
    "$EDITOR_PACKAGE/.build/checkouts/mlx-swift" \
    "$MLX_METALLIB_CACHE"
cp "$MLX_METALLIB_CACHE" "$EDITOR_TEST_MACOS/mlx.metallib"
swift test -c release --disable-index-store --skip-build \
    --package-path "$EDITOR_PACKAGE" \
    -Xswiftc -DCNS_EDITOR_MODEL_TESTS \
    --filter LocalQwenGoldenTests
