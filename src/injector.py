import time
from pynput.keyboard import Controller
from .utils import copy_to_clipboard, send_notification

def inject_text(text):
    """
    Injects text directly into the active application using pynput.
    If it fails (likely due to permissions), copies to clipboard as a fallback.
    """
    if not text:
        return

    keyboard = Controller()
    
    try:
        # Give the UI a tiny bit of time to refocus if needed
        time.sleep(0.1)
        
        # Attempt to type the text directly
        keyboard.type(text)
        print(f"Successfully injected text: {text[:50]}...")
            
    except Exception as e:
        print(f"Direct injection failed: {e}. Falling back to clipboard.")
        copy_to_clipboard(text)
        send_notification("Click-n-speak", "Error", "Injection failed. Text copied to clipboard. Check Accessibility permissions.")
