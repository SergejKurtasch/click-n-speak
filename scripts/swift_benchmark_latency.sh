#!/usr/bin/env bash
# Run only the opt-in real-speech latency benchmark. The Python orchestrator
# validates pinned model bytes and the corpus before invoking this runner.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ "${CNS_LATENCY_BENCHMARKS:-}" = "1" ] || {
    echo "CNS_LATENCY_BENCHMARKS=1 is required" >&2
    exit 2
}
[ -n "${CNS_WHISPER_MODEL:-}" ] && [ -f "$CNS_WHISPER_MODEL" ] || {
    echo "CNS_WHISPER_MODEL must name an existing model file" >&2
    exit 2
}
[ -n "${CNS_WHISPER_MODEL_ID:-}" ] || {
    echo "CNS_WHISPER_MODEL_ID is required" >&2
    exit 2
}
[ -n "${CNS_STT_GOLDEN_DIR:-}" ] \
    && [ -f "$CNS_STT_GOLDEN_DIR/manifest.jsonl" ] \
    && [ -d "$CNS_STT_GOLDEN_DIR/audio_16k" ] || {
    echo "CNS_STT_GOLDEN_DIR must contain manifest.jsonl and audio_16k/" >&2
    exit 2
}
[ -n "${CNS_BENCHMARK_OUTPUT:-}" ] && [ -f "$CNS_BENCHMARK_OUTPUT" ] || {
    echo "CNS_BENCHMARK_OUTPUT must name an existing JSONL output file" >&2
    exit 2
}
[ -n "${CNS_BENCHMARK_INITIAL_PROMPT:-}" ] \
    && [ -n "${CNS_BENCHMARK_USER_TERMS_JSON:-}" ] \
    && [ -n "${CNS_BENCHMARK_PROMPT_SHA256:-}" ] || {
    echo "benchmark dictionary metadata is incomplete" >&2
    exit 2
}
[ -n "${CNS_BENCHMARK_CASE_ID:-}" ] \
    && [ -n "${CNS_BENCHMARK_LANGUAGE_MODE:-}" ] \
    && [ -n "${CNS_BENCHMARK_PIPELINE_PROFILE:-}" ] \
    && [ -n "${CNS_BENCHMARK_MAX_SPEECH_DURATION:-}" ] \
    && [ -n "${CNS_BENCHMARK_REPETITIONS:-}" ] \
    && [ -n "${CNS_BENCHMARK_SCHEDULE:-}" ] \
    && [ -f "${CNS_BENCHMARK_SCHEDULE:-}" ] \
    && [ -n "${CNS_BENCHMARK_MODEL_SHA256:-}" ] \
    && [ -n "${CNS_BENCHMARK_CORPUS_SHA256:-}" ] || {
    echo "benchmark case metadata is incomplete" >&2
    exit 2
}
[ "${CNS_BENCHMARK_PIPELINE_PROFILE:-}" = "full_pipeline_stt_only" ] \
    || [ "${CNS_BENCHMARK_PIPELINE_PROFILE:-}" = "full_pipeline_local_qwen" ] || {
    echo "CNS_BENCHMARK_PIPELINE_PROFILE must select a full pipeline profile" >&2
    exit 2
}
if [ "${CNS_BENCHMARK_PIPELINE_PROFILE}" = "full_pipeline_local_qwen" ]; then
    [ -n "${CNS_QWEN_MODEL_DIR:-}" ] \
        && [ -f "$CNS_QWEN_MODEL_DIR/config.json" ] \
        && [ -f "$CNS_QWEN_MODEL_DIR/tokenizer.json" ] \
        && [ -f "$CNS_QWEN_MODEL_DIR/model.safetensors" ] \
        && [ -n "${CNS_BENCHMARK_QWEN_SHA256:-}" ] || {
        echo "full_pipeline_local_qwen requires a complete Qwen snapshot and checksum" >&2
        exit 2
    }
fi

PACKAGE="$REPO_ROOT/ClickNSpeak"
TEST_ARGS=(
    swift test -c release --disable-index-store
    --package-path "$PACKAGE"
    --filter FullPipelineLatencyBenchmarkTests
)
if [ "${CNS_BENCHMARK_PIPELINE_PROFILE}" = "full_pipeline_local_qwen" ]; then
    # `swift build --build-tests` can reuse a non-testable application module
    # from an earlier release build. Run the selected test suite once with the
    # opt-in benchmark disabled so SwiftPM builds the testable variant before
    # placing the MLX runtime library in its bundle.
    CNS_LATENCY_BENCHMARKS=0 swift test -c release --disable-index-store \
        --package-path "$PACKAGE" \
        --filter FullPipelineLatencyBenchmarkTests
    TEST_BIN="$(find "$PACKAGE/.build" -type d -path '*/release/ClickNSpeakPackageTests.xctest/Contents/MacOS' -print -quit)"
    [ -n "$TEST_BIN" ] && [ -d "$TEST_BIN" ] || {
        echo "ClickNSpeak test bundle not found" >&2
        exit 1
    }
    MLX_SWIFT_VERSION="0.31.4"
    METALLIB_CACHE="$REPO_ROOT/dist/swift/support/mlx-swift-$MLX_SWIFT_VERSION/mlx.metallib"
    "$REPO_ROOT/scripts/build_mlx_metallib.sh" \
        "$PACKAGE/.build/checkouts/mlx-swift" \
        "$METALLIB_CACHE"
    cp "$METALLIB_CACHE" "$TEST_BIN/mlx.metallib"
    TEST_ARGS=(
        swift test -c release --disable-index-store --skip-build
        --package-path "$PACKAGE"
        --filter FullPipelineLatencyBenchmarkTests
    )
fi

echo "==> Running full-pipeline realtime latency benchmark"
"${TEST_ARGS[@]}"
