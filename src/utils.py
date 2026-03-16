import logging
import os
import subprocess
import threading
from pathlib import Path

# Project root (parent of src/)
ROOT = Path(__file__).resolve().parent.parent

# macOS system sounds used for recording feedback (configurable via play_sound argument)
SOUND_RECORDING_START = "/System/Library/Sounds/Tink.aiff"
SOUND_RECORDING_STOP = "/System/Library/Sounds/Pop.aiff"


def get_config_path() -> Path:
    """Returns the path to config.json in the project root."""
    return ROOT / "config.json"


def get_log_file_path() -> Path:
    """Returns the path to the app log file (macOS Library/Logs)."""
    return Path(os.path.expanduser("~/Library/Logs/Click-n-speak.log"))


def escape_applescript_string(s: str) -> str:
    """Escapes a string for safe use inside AppleScript double-quoted literals."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def setup_logging() -> None:
    """Configures logging to file and console."""
    log_file = get_log_file_path()
    try:
        logging.basicConfig(
            filename=log_file,
            level=logging.INFO,
            format="%(asctime)s - %(levelname)s - %(message)s",
        )
    except OSError:
        logging.basicConfig(level=logging.INFO)
        logging.getLogger(__name__).warning("Could not write log file %s, logging to console only.", log_file)

    # Also log to console
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    logging.getLogger("").addHandler(console)


setup_logging()
logger = logging.getLogger(__name__)


def log_info(message: str) -> None:
    logger.info(message)


def log_error(message: str) -> None:
    logger.error(message)


def save_config_to_disk(config: dict) -> None:
    """Writes config dict to config.json in project root. Logs errors."""
    import json

    try:
        with open(get_config_path(), "w") as f:
            json.dump(config, f, indent=4)
    except OSError as e:
        log_error(f"Error saving config: {e}")


def _run_notification(script: str) -> None:
    try:
        subprocess.run(["osascript", "-e", script], check=True)
    except subprocess.CalledProcessError as e:
        log_error(f"Failed to send notification: {e}")


def send_notification(title, subtitle, info_text):
    """Sends a native macOS notification using AppleScript (non-blocking)."""
    content = f"{subtitle} - {info_text}" if subtitle else info_text
    escaped_title = title.replace('"', '\\"')
    escaped_content = content.replace('"', '\\"')

    script = f'display notification "{escaped_content}" with title "{escaped_title}"'
    # Run in a separate thread to avoid blocking the hotkey listener
    threading.Thread(target=_run_notification, args=(script,), daemon=True).start()


def copy_to_clipboard(text):
    """Copies text to the macOS clipboard."""
    try:
        process = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE, close_fds=True)
        process.communicate(input=text.encode("utf-8"))
        log_info("Text copied to clipboard.")
    except Exception as e:
        log_error(f"Failed to copy to clipboard: {e}")


def play_sound(sound_name: str | None = None) -> None:
    """Plays a system sound (non-blocking). Uses SOUND_RECORDING_START if no path given."""
    path = sound_name if sound_name is not None else SOUND_RECORDING_START
    try:
        subprocess.Popen(
            ["afplay", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as e:
        log_error(f"Failed to play sound {path}: {e}")


def is_accessibility_trusted():
    """Checks if the application is a trusted accessibility client."""
    try:
        from ApplicationServices import AXIsProcessTrusted

        return AXIsProcessTrusted()
    except ImportError:
        # If ApplicationServices is not available, we can't be sure
        log_error("ApplicationServices not found, assuming trusted (fallback).")
        return True
    except Exception as e:
        log_error(f"Error checking accessibility permissions: {e}")
        return True
