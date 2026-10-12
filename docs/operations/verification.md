# Verification

## Swift Testing and Verification

Click-n-speak is tested via native Swift Testing across modular packages:

- **Package-level unit tests:**
  ```bash
  swift test --disable-index-store --package-path Packages/<Package>
  ```
  (e.g., `Packages/CNSCore`, `Packages/CNSAudio`, `Packages/CNSUI`, etc.)

- **Application-level tests:**
  ```bash
  swift test --disable-index-store --package-path ClickNSpeak
  ```

- **Full verification suite (all packages):**
  ```bash
  bash scripts/swift_verify.sh
  ```

## Building the App

- **Release application bundle:**
  ```bash
  bash scripts/swift_build_app.sh release
  ```

- **Package into DMG:**
  ```bash
  bash scripts/make_swift_dmg.sh
  ```

## Optional Model-Backed Parity Suites

Real-model integration tests are opt-in and require local model weights:
- Whisper STT parity: set `CNS_RUN_MODEL_TESTS=1` and `CNS_WHISPER_MODEL`
- Local Qwen AI Editor parity: set `CNS_RUN_EDITOR_MODEL_TESTS=1` and `CNS_QWEN_MODEL_DIR`
