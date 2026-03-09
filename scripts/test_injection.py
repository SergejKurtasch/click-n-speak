import time
from pynput.keyboard import Controller

def test_pynput_typing():
    keyboard = Controller()
    print("Test will start in 3 seconds. Please focus a text field (e.g., Notes, TextEdit)...")
    time.sleep(3)
    
    text = "Hello from pynput typing test! 123"
    print(f"Typing: {text}")
    try:
        keyboard.type(text)
        print("Typing complete.")
    except Exception as e:
        print(f"Typing failed: {e}")

if __name__ == "__main__":
    test_pynput_typing()
