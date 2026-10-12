# Click-n-speak Swift Application Guide

The repository root is a 100% native SwiftPM application for macOS.
`ClickNSpeak/`, `Packages/`, native assets, and release scripts are owned here.

## Architecture Overview

- `ClickNSpeak/`: Native composition root and AppKit application delegate (`AppDelegate`, menu setup, runtime coordinator).
- `Packages/`: Modular Swift packages:
  - `CNSCore`: Configuration (`Config.swift`), paths, models, logging, and base protocols.
  - `CNSAudio`: Audio input engine, microphone capture, ring buffers, and level monitoring.
  - `CNSTranscription`: Local Whisper.cpp engine, model download manager, and cloud transcription APIs (Gemini, OpenAI).
  - `CNSEditors`: AI Editor formatting pipelines (MLX Qwen / Gemini API).
  - `CNSDictionary`: Self-learning dictionary, phrase history, and custom text replacements.
  - `CNSSession`: Dictation state machine, audio recording lifecycle, and text injection coordinator.
  - `CNSInput`: Global Carbon hotkey manager (`⌥ Option + Space`) and accessibility text injection.
  - `CNSUI`: Status bar menu item, interactive HUD floating editor ("edit before insert"), setup wizard, and setting panels.
- `scripts/`: Native build, test verification, packaging (DMG), and release notarization scripts.

## Data Ownership & Safety Invariants

- Preserve existing user paths in `~/Library/Application Support/Click-n-speak/` (`config.json`, `phrase_history.txt`, `corrections.json`).
- Audio capture must stop promptly on session completion. Never leave the microphone active when idle.
- UI operations must run on `@MainActor`. Heavy transcription or inference tasks run in background actors.

## Working Rules

- Responses, plans, and chat discussions: Russian.
- Code, comments, docstrings, and commit messages: English.
- Preserve unrelated working-tree changes. Never discard or overwrite them.
- Use conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`, `test:`, `docs:`.
- Never commit secrets, `.env`, transcripts, prompts, model artifacts, or user configuration.

## Verification Commands

Run the full Swift verification suite (all packages):

```bash
bash scripts/swift_verify.sh
```

Build the release application:

```bash
bash scripts/swift_build_app.sh release
```
