# Click-n-speak 🎙️

Click-n-speak is a lightweight, local, and cross-platform (focused on macOS) speech recognition tool that runs seamlessly in your Menu Bar. It uses **MLX Whisper** for fast, on-device transcription leveraging Apple Silicon GPUs, and allows you to inject recognized text directly into any active application using global hotkeys.

## 🔥 Key Features

- **100% Local & Private**: All speech recognition happens on your machine. No data is sent to the cloud.
- **Apple Silicon Optimized**: Powered by [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper), achieving blazingly fast transcription speeds.
- **Global Hotkey Integration**: Press `<alt>+<space>` anywhere to start speaking, and the text will be injected right where your cursor is.
- **Multilingual Support on the Fly**: Seamlessly transcribes multiple languages without needing to change system keyboard layouts.
- **Adaptive Silence Detection**: Automatically handles micro-pauses (for thinking) and longer pauses to trigger transcription naturally.
- **Menu Bar Control**: Easily select models, change primary languages, tweak microphone sensitivity, or set the app to launch at login.

## 🛠 Tech Stack

- **Python 3.10+**
- **MLX Whisper** - For fast inference.
- **Pynput & ApplicationServices** - For global hotkey listening and text injection.
- **Sounddevice** - For listening to microphone streams.
- **Rumps** - For the native macOS menu bar interface.

## 🚀 Installation & Setup (Development)

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/Click-n-speak.git
   cd Click-n-speak
   ```

2. **Set up a virtual environment:**
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   ```

3. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```
   *Note: On macOS, `pynput` and text injection require Accessibility permissions.*

4. **Run the App:**
   ```bash
   python main.py
   ```

## 📦 Building a macOS `.app` Bundle

To distribute Click-n-speak as a standalone macOS application:

1. Ensure all dependencies (plus `py2app`) are installed in your `venv`.
2. Run the build script to safely package everything (bypassing macOS SIP constraints):
   ```bash
   bash scripts/build.sh
   ```
3. The packaged app will be available in the `dist/` directory as `Click-n-speak.app`.

### ⚠️ Important: macOS Accessibility Permissions
For the bundled `Click-n-speak.app` to listen to global hotkeys and inject text, you **must** grant it permissions in macOS System Settings:
1. Go to **System Settings** -> **Privacy & Security**.
2. Navigate to **Accessibility**.
3. Click the `+` button and add `dist/Click-n-speak.app`.
4. Ensure the toggle is turned ON.
5. (Optional) Check **Input Monitoring** to ensure hotkeys are intercepted globally.

## ⚙️ Configuration

The app relies on a `config.json` file in the root directory. You can edit this file directly or use the Menu Bar UI:
```json
{
    "autostart": false,
    "model_name": "mlx-community/whisper-large-v3-mlx",
    "languages": ["ru", "en"],
    "silence_duration": 1.0
}
```

## 📝 License

MIT License. See [LICENSE](LICENSE) for details.
