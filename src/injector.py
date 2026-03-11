import time
from pynput.keyboard import Controller
from .utils import copy_to_clipboard, send_notification, is_accessibility_trusted, log_info, log_error

def inject_text(text):
    """
    Injects text directly into the active application using pynput.
    If it fails (likely due to permissions), copies to clipboard as a fallback.
    """
    if not text:
        return

    # Check for accessibility permissions
    if not is_accessibility_trusted():
        log_error("Accessibility permissions NOT granted. Skipping direct injection.")
        copy_to_clipboard(text)
        send_notification(
            "Click-n-speak", 
            "Permissions Required", 
            "Please allow Click-n-speak in System Settings -> Privacy -> Accessibility to enable text injection."
        )
        return

    keyboard = Controller()
    
    try:
        # Give the UI a tiny bit of time to refocus if needed
        time.sleep(0.1)
        
        # Attempt to type the text directly
        log_info(f"Attempting to inject text: {text[:50]}...")
        keyboard.type(text)
        log_info("Text injection successful.")
            
    except Exception as e:
        log_error(f"Direct injection failed: {e}. Falling back to clipboard.")
        copy_to_clipboard(text)
        send_notification(
            "Click-n-speak", 
            "Injection Failed", 
            "Could not inject text. Check Accessibility permissions or use clipboard."
        )
