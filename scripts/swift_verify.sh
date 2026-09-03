#!/usr/bin/env bash
# Canonical fast verification gate for the Swift migration.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES=(
    CNSCore
    CNSAudio
    CNSInput
    CNSEditors
    CNSTranscription
    CNSDictionary
    CNSSession
    CNSUI
)

for package in "${PACKAGES[@]}"; do
    echo "==> Testing $package"
    swift test --disable-index-store --package-path "$REPO_ROOT/Packages/$package"
    if [ "${CNS_CLEAN_AFTER_PACKAGE:-0}" = "1" ]; then
        echo "==> Cleaning generated build artifacts for $package"
        swift package --package-path "$REPO_ROOT/Packages/$package" clean
    fi
done

echo "==> Testing ClickNSpeak"
swift test --disable-index-store --package-path "$REPO_ROOT/ClickNSpeak"

if [ "${CNS_RUN_MODEL_TESTS:-0}" = "1" ]; then
    if [ -z "${CNS_WHISPER_MODEL:-}" ]; then
        echo "CNS_RUN_MODEL_TESTS=1 requires CNS_WHISPER_MODEL" >&2
        exit 1
    fi
    GOLDEN_DIR="${CNS_STT_GOLDEN_DIR:-$REPO_ROOT/spikes/stt-bakeoff/golden}"
    if [ ! -f "$GOLDEN_DIR/manifest.jsonl" ] || [ ! -d "$GOLDEN_DIR/audio_16k" ]; then
        echo "CNS_RUN_MODEL_TESTS=1 requires CNS_STT_GOLDEN_DIR with manifest.jsonl and audio_16k/" >&2
        exit 1
    fi
    echo "==> Running real-model 42-phrase golden parity suite"
    # Performance thresholds must exercise the optimized code path that ships;
    # debug actor/task overhead is not comparable to the accepted release bake-off.
    CNS_STT_GOLDEN_DIR="$GOLDEN_DIR" swift test -c release \
        --disable-index-store \
        --package-path "$REPO_ROOT/Packages/CNSTranscription" \
        -Xswiftc -DCNS_MODEL_TESTS
else
    echo "==> Real-model job not selected; set CNS_RUN_MODEL_TESTS=1 and CNS_WHISPER_MODEL"
fi

if [ "${CNS_RUN_EDITOR_MODEL_TESTS:-0}" = "1" ]; then
    if [ -z "${CNS_QWEN_MODEL_DIR:-}" ]; then
        echo "CNS_RUN_EDITOR_MODEL_TESTS=1 requires CNS_QWEN_MODEL_DIR" >&2
        exit 1
    fi
    if [ ! -f "$CNS_QWEN_MODEL_DIR/config.json" ] \
        || [ ! -f "$CNS_QWEN_MODEL_DIR/tokenizer.json" ] \
        || [ ! -f "$CNS_QWEN_MODEL_DIR/model.safetensors" ]; then
        echo "CNS_QWEN_MODEL_DIR must contain a complete local MLX snapshot" >&2
        exit 1
    fi
    echo "==> Running real-model local Qwen editor parity suite"
    EDITOR_PACKAGE="$REPO_ROOT/Packages/CNSEditors"
    swift build -c release --build-tests --disable-index-store \
        --package-path "$EDITOR_PACKAGE" \
        -Xswiftc -enable-testing \
        -Xswiftc -DCNS_EDITOR_MODEL_TESTS
    EDITOR_BIN_DIR="$(swift build -c release --show-bin-path --package-path "$EDITOR_PACKAGE")"
    EDITOR_TEST_MACOS="$EDITOR_BIN_DIR/CNSEditorsPackageTests.xctest/Contents/MacOS"
    if [ ! -d "$EDITOR_TEST_MACOS" ]; then
        echo "CNSEditors test bundle not found: $EDITOR_TEST_MACOS" >&2
        exit 1
    fi
    MLX_SWIFT_VERSION="0.31.4"
    MLX_METALLIB_CACHE="$REPO_ROOT/dist/swift/support/mlx-swift-$MLX_SWIFT_VERSION/mlx.metallib"
    "$REPO_ROOT/scripts/build_mlx_metallib.sh" \
        "$EDITOR_PACKAGE/.build/checkouts/mlx-swift" \
        "$MLX_METALLIB_CACHE"
    cp "$MLX_METALLIB_CACHE" "$EDITOR_TEST_MACOS/mlx.metallib"
    swift test -c release --disable-index-store --skip-build \
        --package-path "$EDITOR_PACKAGE" \
        -Xswiftc -DCNS_EDITOR_MODEL_TESTS
else
    echo "==> Editor real-model job not selected; set CNS_RUN_EDITOR_MODEL_TESTS=1 and CNS_QWEN_MODEL_DIR"
fi

echo "Swift verification passed"
