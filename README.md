# Click-n-speak

A macOS menu-bar app for local, private speech-to-text. Press a hotkey anywhere, speak, and the transcribed text is typed directly into the active application.

All processing runs on-device using Apple Silicon — no data leaves your machine.

## Features

- **100% local** — Whisper via MLX, no cloud, no internet required for transcription
- **AI cleanup** — optional Qwen 2.5 1.5B (4-bit) post-processes each transcription for punctuation and grammar (8s timeout)
- **Global hotkey** — `Alt+Space` starts and stops recording from any app
- **Adaptive VAD** — silence detection adjusts to speech pace; short pauses buffer, longer pauses trigger send
- **Multilingual** — primary + additional languages in one session, no layout switching
- **Auto vocabulary** — analyzes phrase history every 50 transcriptions, suggests (or auto-adds) domain terms to improve Whisper accuracy; configurable in Suggest / Auto / Disabled mode
- **Setup wizard** — first-launch wizard guides through all required permissions automatically
- **Menu bar UI** — model selection, language config, vocabulary management, phrase history with copy
- **Clean shutdown** — no orphan MLX helper processes left behind, even after Force Quit or crash (kqueue-driven parent-death watchdog + startup sweep)

## Requirements

- macOS 13+ (Apple Silicon recommended)
- Python 3.11

## Quick Start

Download the latest `.dmg` from the [Releases](https://github.com/SergejKurtasch/click-n-speak/releases) page, open it, and drag **Click-n-speak.app** to `/Applications`.

On first launch a setup wizard walks through granting Microphone, Accessibility, and Input Monitoring permissions.

## Development Setup

```bash
git clone https://github.com/SergejKurtasch/click-n-speak.git
cd click-n-speak
python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python main.py
```

## Building a .app Bundle

Two build paths are available:

**py2app bundle** (faster build, larger size):
```bash
bash scripts/build.sh
```

**Launcher bundle** (native C launcher, correct TCC attribution):
```bash
bash scripts/build_launcher.sh
bash scripts/install.sh        # copies to /Applications
```

The built app lands in `dist/Click-n-speak.app`. After each build, TCC permissions reset automatically — re-add the app in System Settings when prompted.

To create a distributable DMG:
```bash
bash scripts/make_dmg.sh
```

## Configuration

The app stores its config in `~/Library/Application Support/Click-n-speak/config.json`. Key fields:

```json
{
    "schema_version": 4,
    "primary_language": "ru",
    "additional_languages": ["en"],
    "model_name": "mlx-community/whisper-large-v3-turbo",
    "ai_editor_enabled": true,
    "ai_editor_model": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
    "user_terms": {"ru": ["термин1"], "en": ["PCA"]},
    "prompt_update_mode": "suggest",
    "auto_prompt_check_interval": 50,
    "silence_duration": 1.0,
    "target_speech_duration": 4.0,
    "max_speech_duration": 8.0,
    "autostart": false
}
```

`user_terms` — domain vocabulary injected into Whisper's initial prompt for better accuracy. Updated manually via *Edit Terms* or automatically via the auto-vocabulary feature.

`prompt_update_mode` — controls auto-vocabulary: `"suggest"` (review before adding), `"auto"` (add immediately), `"disabled"`.

All fields are also editable via the menu bar UI.

## Tech Stack

| Component | Library |
|---|---|
| Speech recognition | [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) |
| AI text cleanup | [mlx-lm](https://github.com/ml-explore/mlx-lm) + Qwen 2.5 1.5B |
| Voice activity detection | webrtcvad |
| Global hotkeys | pynput |
| Audio capture | sounddevice |
| Menu bar UI | rumps |
| macOS permissions | pyobjc (Cocoa, Quartz, ApplicationServices, AVFoundation) |

## Running Tests

```bash
source venv/bin/activate
pytest tests/
```

## License

MIT License. See [LICENSE](LICENSE) for details.
