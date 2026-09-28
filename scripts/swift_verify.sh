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
    if [ "$package" = "CNSSession" ]; then
        # Xcode 16.4's Swift 6.1.2 frontend crashes while batch-compiling this
        # test target on the macOS arm64 runner. Compile files independently
        # until the runner toolchain includes the upstream compiler fix.
        swift test --disable-index-store --package-path "$REPO_ROOT/Packages/$package" \
            -Xswiftc -disable-batch-mode
    else
        swift test --disable-index-store --package-path "$REPO_ROOT/Packages/$package"
    fi
    if [ "${CNS_CLEAN_AFTER_PACKAGE:-0}" = "1" ]; then
        echo "==> Cleaning generated build artifacts for $package"
        swift package --package-path "$REPO_ROOT/Packages/$package" clean
    fi
done

echo "==> Testing ClickNSpeak"
swift test --disable-index-store --package-path "$REPO_ROOT/ClickNSpeak"

if [ "${CNS_RUN_MODEL_TESTS:-0}" = "1" ]; then
    echo "==> Running real-model 42-phrase golden parity suite"
    bash "$REPO_ROOT/scripts/swift_verify_stt_model.sh"
else
    echo "==> Real-model job not selected; set CNS_RUN_MODEL_TESTS=1 and CNS_WHISPER_MODEL"
fi

if [ "${CNS_RUN_EDITOR_MODEL_TESTS:-0}" = "1" ]; then
    echo "==> Running real-model local Qwen editor parity suite"
    bash "$REPO_ROOT/scripts/swift_verify_editor_model.sh"
else
    echo "==> Editor real-model job not selected; set CNS_RUN_EDITOR_MODEL_TESTS=1 and CNS_QWEN_MODEL_DIR"
fi

echo "Swift verification passed"
