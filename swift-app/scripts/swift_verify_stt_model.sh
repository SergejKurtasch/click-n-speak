#!/usr/bin/env bash
# Run only the real-model Whisper golden suite for acceptance.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "${CNS_WHISPER_MODEL:-}" ] && [ -f "$CNS_WHISPER_MODEL" ] || {
    echo "CNS_WHISPER_MODEL must name an existing model file" >&2
    exit 2
}
MODEL_FILE="$(basename "$CNS_WHISPER_MODEL")"
if [ -z "${CNS_WHISPER_MODEL_ID:-}" ]; then
    case "$MODEL_FILE" in
        ggml-large-v3-turbo.bin) CNS_WHISPER_MODEL_ID="whisper-large-v3-turbo" ;;
        ggml-large-v3.bin) CNS_WHISPER_MODEL_ID="whisper-large-v3" ;;
        ggml-medium.bin) CNS_WHISPER_MODEL_ID="whisper-medium" ;;
        ggml-small.bin) CNS_WHISPER_MODEL_ID="whisper-small" ;;
        ggml-base.bin) CNS_WHISPER_MODEL_ID="whisper-base" ;;
        *)
            echo "CNS_WHISPER_MODEL_ID is required for an unknown model filename" >&2
            exit 2
            ;;
    esac
else
    case "$CNS_WHISPER_MODEL_ID:$MODEL_FILE" in
        whisper-large-v3-turbo:ggml-large-v3-turbo.bin \
        |whisper-large-v3:ggml-large-v3.bin \
        |whisper-medium:ggml-medium.bin \
        |whisper-small:ggml-small.bin \
        |whisper-base:ggml-base.bin) ;;
        whisper-large-v3-turbo:*|whisper-large-v3:*|whisper-medium:*|whisper-small:*|whisper-base:*)
            echo "CNS_WHISPER_MODEL_ID does not match CNS_WHISPER_MODEL filename" >&2
            exit 2
            ;;
        *) ;;
    esac
fi
export CNS_WHISPER_MODEL_ID
GOLDEN_DIR="${CNS_STT_GOLDEN_DIR:-$REPO_ROOT/spikes/stt-bakeoff/golden}"
[ -f "$GOLDEN_DIR/manifest.jsonl" ] && [ -d "$GOLDEN_DIR/audio_16k" ] || {
    echo "CNS_STT_GOLDEN_DIR must contain manifest.jsonl and audio_16k/" >&2
    exit 2
}

CNS_STT_GOLDEN_DIR="$GOLDEN_DIR" swift test -c release \
    --disable-index-store \
    --package-path "$REPO_ROOT/Packages/CNSTranscription" \
    -Xswiftc -DCNS_MODEL_TESTS \
    --filter WhisperCppTranscriberTests
