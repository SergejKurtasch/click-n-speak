import sys
import os
import time
import threading

# Add src to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from src.utils import play_sound, send_notification

def test_play_sound():
    print("Testing play_sound (should be non-blocking)...")
    start = time.time()
    play_sound("/System/Library/Sounds/Tink.aiff")
    end = time.time()
    duration = end - start
    print(f"play_sound call took: {duration:.4f}s")
    if duration < 0.1:
        print("✅ play_sound is non-blocking.")
    else:
        print("❌ play_sound might be blocking.")

def test_send_notification():
    print("\nTesting send_notification (should be non-blocking)...")
    start = time.time()
    send_notification("Test", "Subtitle", "This is a test notification")
    end = time.time()
    duration = end - start
    print(f"send_notification call took: {duration:.4f}s")
    if duration < 0.1:
        print("✅ send_notification is non-blocking.")
    else:
        print("❌ send_notification might be blocking.")

if __name__ == "__main__":
    test_play_sound()
    test_send_notification()
    print("\nWaiting a bit for background processes to finish...")
    time.sleep(2)
    print("Done.")
