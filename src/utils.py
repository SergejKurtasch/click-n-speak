import subprocess
import threading
import os
import logging

# Setup logging
LOG_FILE = os.path.expanduser("~/Library/Logs/Click-n-speak.log")

def setup_logging():
    try:
        logging.basicConfig(
            filename=LOG_FILE,
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s'
        )
    except Exception:
        # Fallback if logging to file fails (e.g. permissions)
        logging.basicConfig(level=logging.INFO)
    
    # Also log to console
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    logging.getLogger('').addHandler(console)

setup_logging()
logger = logging.getLogger(__name__)

def log_info(message):
    logger.info(message)

def log_error(message):
    logger.error(message)

def _run_notification(script):
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
        process = subprocess.Popen(['pbcopy'], stdin=subprocess.PIPE, close_fds=True)
        process.communicate(input=text.encode('utf-8'))
        log_info("Text copied to clipboard.")
    except Exception as e:
        log_error(f"Failed to copy to clipboard: {e}")

def play_sound(sound_name="/System/Library/Sounds/Tink.aiff"):
    """Plays a system sound (non-blocking)."""
    try:
        # Popen is non-blocking
        subprocess.Popen(["afplay", sound_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        log_error(f"Failed to play sound {sound_name}: {e}")

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
