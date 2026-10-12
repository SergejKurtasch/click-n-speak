# Click-n-speak

Click-n-speak is a fast, lightweight, and privacy-first macOS menu bar application for seamless speech-to-text dictation directly into any active window or text field.

---

## ✨ Features

- **Global Hotkey:** Start and stop dictation from anywhere in macOS using a single global keyboard shortcut (`⌥ Option + Space`).
- **Interactive HUD Editor ("Edit Before Insert"):** Instead of blind text insertion, a sleek floating HUD window appears near your cursor showing the transcribed text. You can review it, make quick edits, and press `Enter` to paste it into your target app, or `Esc` to cancel.
- **100% Free & Offline (Local Models):** High-accuracy speech recognition powered by local Whisper models running directly on your Mac. No internet required, zero subscription fees, total privacy.
- **Cloud STT Alternatives:** Built-in support for Gemini API and OpenAI Whisper API for users who prefer cloud transcription or want to save battery on older machines.
- **AI Text Refinement (Smart Punctuation & Formatting):** An integrated AI Editor automatically inserts punctuation, capitalizes sentences, removes filler words, and structures text. Works locally via Qwen 2.5 (powered by Apple Silicon MLX) or via the Gemini API.
- **Self-Learning Dictionary & Replacements:**
  - Select any word in the popup editor and press `⌘ Command + D` to instantly add it to your custom vocabulary.
  - Suggests frequently used words and corrections from your dictation history.
  - Custom text replacement rules to fix persistent recognition quirks.
- **Audio/Video File Transcription:** Drag-and-drop any audio or video file to transcribe it with optional AI refinement and export to `.txt`.
- **100% Native Swift:** Built entirely with native Swift and Swift Package Manager (SwiftPM). No Electron, no Python runtime overhead, and instant responsiveness.

---

## 💾 Local Models & Disk Space

Click-n-speak allows you to use voice recognition **completely free and offline** without requiring any paid API keys.

- **First-Time Model Download:** Upon first use or when selecting a local model from the menu, the app downloads the model files directly from Hugging Face into your local Application Support directory.
- **Disk Space Usage:** Local models range in size from **~150 MB up to ~3 GB** depending on your choice:
  - `Base`: ~148 MB *(fastest, low memory)*
  - `Small`: ~488 MB *(balanced)*
  - `Turbo (large-v3-turbo)`: ~1.6 GB *(recommended default, fast and highly accurate)*
  - `Medium`: ~1.5 GB
  - `Large v3`: ~3.1 GB *(highest accuracy)*
  - `Local AI Editor (Qwen 2.5 1.5B via MLX)`: ~880 MB *(optional local text post-processing)*
- **Model Management:** You can safely delete downloaded models at any time via the **"Delete local models..."** menu item to free up disk space.

---

## ⌨️ Hotkeys Cheatsheet

| Shortcut | Context | Description |
|---|---|---|
| **`⌥ Option + Space`** | Global (anywhere in macOS) | **Start / Stop Dictation**. Press once to start recording, press again to stop and begin recognition. |
| **`Enter`** / **`Return`** | Interactive HUD Popup | **Confirm & Paste**. Closes the popup and automatically types/pastes the text into your active app. |
| **`Esc`** | Interactive HUD Popup | **Cancel**. Closes the popup without inserting text. |
| **`⌘ Command + D`** | Interactive HUD Popup | **Add Term to Dictionary**. Highlight any word or phrase with your mouse and press `⌘D` to save it to your Whisper vocabulary. |
| **`⌥ Option + Space`** | While HUD Popup is Open | **Append Speech**. Continue speaking to append newly recognized text to the active draft. |
| **`⌘ Command + Q`** | Menu Bar Item | **Quit** Click-n-speak. |

---

## 🎛 Menu Bar Guide

Click-n-speak lives unobtrusively in your macOS status bar. Here is what each menu section does:

- **Permissions:** Displays the status of required macOS permissions (**Microphone** and **Accessibility**). Clicking either item directly opens the corresponding section in macOS System Settings.
- **Model:**
  - *Runtime Status:* Shows current engine status (Ready, Preparing, Downloading, Error).
  - *Cloud Models:* Switch to cloud-based recognition (Gemini 2.5 Flash, GPT-4o mini, OpenAI Whisper).
  - *Local Models:* Choose your local Whisper model (`Turbo`, `Large v3`, `Medium`, `Small`, `Base`). Clicking an uninstalled model starts downloading it in the background with a live progress indicator.
- **API Keys:** Securely store your Google Gemini or OpenAI API keys in the macOS Keychain for cloud features.
- **Languages:**
  - *Primary Language:* Choose your primary dictation language (`ru`, `en`, `uk`, `de`, `es`, `fr`).
  - *Additional Languages:* Select secondary languages for multilingual dictation.
  - *Auto-detect Language:* Allow the model to detect speech language automatically.
- **AI Editor Backend:** Choose how punctuation and text polishing should be handled:
  - *Disabled:* Raw Whisper output is pasted directly.
  - *Local (Qwen via MLX):* Offline local LLM on Apple Silicon.
  - *Gemini API:* Cloud-based text formatting.
- **Delete local models...:** Safely delete downloaded model weights to reclaim disk space.
- **Dictionary (Vocabulary):**
  - *Edit terms:* View and edit your custom terms, brand names, and technical jargon.
  - *Revert terms:* Roll back to an earlier vocabulary snapshot.
  - *Update mode:* Choose how new terms are handled (`Suggest`, `Auto`, or `Disabled`).
  - *Review suggestions:* Inspect frequently dictated words discovered from your history.
  - *Replacements:* Manage text substitution rules (e.g., misrecognized acronyms).
  - *Statistics:* View dictionary hit rate, edit frequency, and model performance.
- **Last Phrases:** Recent transcription history. Click any phrase to instantly copy it to the clipboard.
- **Transcribe Audio File...:** Open a drag-and-drop window to transcribe recorded audio and video files.
- **Setup Wizard...:** Step-by-step assistant for granting system permissions.
- **Check for updates:** Checks for new releases on GitHub with one-click in-app update support.
- **Launch at Login:** Automatically start Click-n-speak when you log in to macOS.
- **Advanced:** Quick access to edit `config.json`, open logs, or reload configuration without restarting.
- **Restart / Quit:** Gracefully restart or quit the application.

---

## 💡 Pro Tips for Best Accuracy

1. **Select Only the Languages You Speak:**
   In the **Languages** menu, select only the languages you actually intend to dictate. Limiting the language pool prevents the model from hallucinating or mistakenly switching to an unrelated language.
2. **Train Your Dictionary (`⌘D`):**
   If Whisper misrecognizes a specific company name, programming term, or slang, highlight it in the popup editor and press `⌘D`. Whisper will prioritize this spelling in future dictations.
3. **Use the AI Editor for Natural Speaking:**
   You do not need to dictate punctuation marks out loud (no need to say "comma" or "period"). Let the AI Editor format punctuation, capitalization, and paragraphs naturally.

---

## 🚀 Installation (For Regular Users)

You do **not** need Xcode or any developer tools to run Click-n-speak.

1. Go to the **[Releases](https://github.com/SergejKurtasch/click-n-speak/releases/latest)** section on GitHub.
2. Download **`Click-n-speak-macOS.dmg`**.
3. Open the DMG file and drag **Click-n-speak** into your **Applications** folder.
4. Launch **Click-n-speak**. The app icon will appear in your top menu bar.
5. Follow the **Setup Wizard** to grant Microphone and Accessibility permissions.
6. The app will automatically download the necessary local model upon first dictation, or you can pick one from the **Model** menu.

---

## 🛠 Building from Source (For Developers)

If you want to build and compile the application yourself from the repository, **Xcode is required on your Mac**.

### Prerequisites
- macOS 14.0 (Sonoma) or newer (Apple Silicon Mac recommended).
- **Xcode 15+** installed (available from the Mac App Store or Apple Developer portal).
  - Full Xcode is required because the project compiles Metal compute kernels for `mlx-swift` via `xcodebuild` and `xcrun -f metal`.
  - Ensure command-line tools point to Xcode:
    ```bash
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    ```
- Git and Swift toolchain (included with Xcode).

### Build Steps

1. **Clone the repository:**
   ```bash
   git clone https://github.com/SergejKurtasch/click-n-speak.git
   cd click-n-speak
   ```

2. **Build the application bundle:**
   Run the build script:
   ```bash
   bash scripts/swift_build_app.sh release
   ```
   > 💡 *Note on TCC Permissions:* By default, local development builds reset system permissions for testing. To preserve your existing microphone and accessibility permissions across builds, run:
   > ```bash
   > CNS_RESET_TCC_AFTER_BUILD=0 bash scripts/swift_build_app.sh release
   > ```

3. **Launch the built app:**
   The compiled application bundle is placed in `dist/swift/`:
   ```bash
   open dist/swift/Click-n-speak.app
   ```

4. **Create a release DMG installer (optional):**
   ```bash
   bash scripts/make_swift_dmg.sh
   ```
   The `.dmg` file will be generated in `dist/`.

### Running Tests & Verification
```bash
# Run unit tests across packages
swift test --disable-index-store --package-path Packages/CNSCore
swift test --disable-index-store --package-path ClickNSpeak

# Run workspace verification gates (all packages)
bash scripts/swift_verify.sh
```

---

## 🔒 macOS Permissions

Click-n-speak requires two macOS permissions to operate:
- **Microphone (`NSMicrophoneUsageDescription`):** Required to capture your voice for speech recognition.
- **Accessibility:** Required to inject (paste) transcribed text into your currently focused application and restore cursor focus.

*(Note: Click-n-speak uses native Carbon global hotkeys, so Input Monitoring permission is not required).*
