#!/usr/bin/env bash
# Run only the real-model Whisper golden suite for acceptance.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "${CNS_WHISPER_MODEL:-}" ] && [ -d "$CNS_WHISPER_MODEL" ] || {
    echo "CNS_WHISPER_MODEL must name an existing model directory" >&2
    exit 2
}
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
