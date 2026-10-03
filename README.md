# Click-n-speak

Click-n-speak is a convenient macOS menu bar application for seamless speech-to-text dictation directly into any active window.

## ✨ Features

- **Global Hotkey:** Start and stop recording from anywhere using a customizable keyboard shortcut.
- **Auto-Injection:** Transcribed text is automatically pasted into your active macOS application.
- **Edit Before Insert:** An optional popup window allows you to review and manually edit the transcribed text before it gets inserted.
- **Offline & Cloud STT:**
  - **Local (Offline):** Automatically downloads and uses local Whisper models for privacy-first, on-device transcription.
  - **Cloud:** Supports OpenAI and Gemini APIs for alternative transcription backends.
- **AI Text Refinement:** Uses an AI Editor (via local MLX models like Qwen, or Cloud APIs) to automatically fix punctuation, formatting, and grammar before pasting.
- **100% Native:** Built entirely with native Swift for macOS, ensuring high performance, a small footprint, and deep system integration.

## 💡 Pro Tip: Language Selection
For the highest recognition accuracy, **select only the languages you actually speak** in the application settings. Limiting the active languages helps the model avoid "hallucinations" and prevents it from incorrectly switching to an unintended language, dramatically improving overall transcription quality.

## 🚀 Installation & Usage

1. Go to the **[Releases](https://github.com/SergejKurtasch/click-n-speak/releases/latest)** section on GitHub.
2. Download the **`Click-n-speak-macOS.dmg`** file.
3. Open the DMG and drag the application to your `Applications` folder.
4. Launch the application. It will appear in your top macOS menu bar.

*Note: The application will **automatically download** the necessary local models for voice recognition upon first use. You do not need to configure them manually! If you prefer cloud recognition (e.g., to save battery or for different quality), simply enter your API keys in the settings.*

## 🛠 Development

The application is written entirely in native Swift using Swift Package Manager (SwiftPM).

*(Note: The old Python version of the application has been completely removed from the repository).*

**Running tests and local validation:**
```bash
swift test --disable-index-store --package-path Packages/CNSCore
swift test --disable-index-store --package-path ClickNSpeak
bash scripts/swift_verify.sh
```
