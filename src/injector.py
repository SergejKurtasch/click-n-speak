import time

from pynput.keyboard import Controller, Key

from .utils import is_accessibility_trusted, log_error, log_info, send_notification

def inject_text(text, pre_delay: float = 0.0):
    """
    Injects text directly into the active application using pynput by typing
    character by character with a micro-delay to prevent dropped characters.

    pre_delay: optional sleep before typing (seconds). Callers that have already
               waited for focus restore should pass 0.0.
    """
    if not text:
        return

    # Check for accessibility permissions
    if not is_accessibility_trusted():
        log_error("Accessibility permissions NOT granted. Cannot type text.")
        send_notification(
            "Click-n-speak",
            "Permissions Required",
            "Please allow Click-n-speak in System Settings -> Privacy -> Accessibility to enable text typing.",
        )
        return

    keyboard = Controller()

    try:
        if pre_delay > 0:
            time.sleep(pre_delay)

        # Release modifiers in case they are virtually stuck from the hotkey
        for k in (Key.alt, Key.cmd, Key.shift, Key.ctrl):
            keyboard.release(k)

        log_info(f"Attempting to inject text (typing mode): {text[:50]}...")

        # Type text character by character with a small delay
        for char in text:
            keyboard.type(char)
            # 2ms delay is enough to avoid UI buffer skips in most IDEs/Browsers
            time.sleep(0.002)

        log_info("Text injection successful (via keyboard typing).")

    except Exception as e:
        log_error(f"Direct injection failed: {e}")
        send_notification(
            "Click-n-speak",
            "Injection Failed",
            "Could not type text. Check Accessibility permissions.",
        )
