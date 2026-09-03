#!/usr/bin/env bash
# Build a self-contained whisper.xcframework (macOS arm64, static, embedded
# Metal) for the CNSTranscription package to vendor as a binaryTarget.
#
# Reproducible: clones a pinned whisper.cpp commit, builds static libs with
# cmake, merges them into one archive, and assembles the xcframework with the
# headers CNSTranscription needs. The result is gitignored (regenerate with this
# script); only the script is committed.
#
# Requirements: cmake, Xcode command-line tools. Run from anywhere:
#   ./scripts/build_whisper_xcframework.sh
set -euo pipefail

# Pinned whisper.cpp release used by the accepted Phase 0 bake-off. Keep the
# runtime and its quality/latency thresholds on the same decoder revision;
# update both deliberately after a complete golden-corpus run.
WHISPER_CPP_COMMIT="v1.9.1"
WHISPER_CPP_REPO="https://github.com/ggml-org/whisper.cpp.git"

export PATH="/opt/homebrew/bin:$PATH"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/Packages/CNSTranscription/Vendor/whisper.xcframework"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cloning whisper.cpp @ ${WHISPER_CPP_COMMIT:0:10}"
git clone --quiet "$WHISPER_CPP_REPO" "$WORK/src"
git -C "$WORK/src" fetch --quiet --depth 1 origin "$WHISPER_CPP_COMMIT"
git -C "$WORK/src" checkout --quiet "$WHISPER_CPP_COMMIT"

echo "==> Building static libs (macOS arm64, embedded Metal)"
cmake -S "$WORK/src" -B "$WORK/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
cmake --build "$WORK/build" --config Release -j"$(sysctl -n hw.ncpu)" >/dev/null

echo "==> Merging static archives"
LIBS=$(find "$WORK/build" -name "libwhisper.a" -o -name "libggml.a" -o -name "libggml-base.a" \
    -o -name "libggml-cpu.a" -o -name "libggml-blas.a" -o -name "libggml-metal.a")
libtool -static -o "$WORK/libwhisper_combined.a" $LIBS 2>/dev/null

echo "==> Assembling headers"
HDR="$WORK/Headers"
mkdir -p "$HDR"
cp "$WORK/src/include/whisper.h" "$HDR/"
for h in ggml ggml-cpu ggml-alloc ggml-backend ggml-metal gguf; do
    cp "$WORK/src/ggml/include/$h.h" "$HDR/" 2>/dev/null || true
done
cat > "$HDR/module.modulemap" <<'MODMAP'
module whisper {
    header "whisper.h"
    export *
}
MODMAP

echo "==> Creating xcframework"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
    -library "$WORK/libwhisper_combined.a" \
    -headers "$HDR" \
    -output "$OUT" >/dev/null

echo "==> Done: $OUT"
du -sh "$OUT"
