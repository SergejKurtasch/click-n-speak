import numpy as np
import time
import sys
import os

# Add src to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from src.recorder import AudioRecorder

def test_callback(chunk):
    print(f"\n[Test] Chunk received! Size: {len(chunk)} samples ({len(chunk)/16000:.2f}s)")
    energy = np.sqrt(np.mean(chunk**2))
    print(f"[Test] Chunk energy: {energy:.4f}")

def main():
    print("Testing AudioRecorder silence detection and chunking...")
    print("Please speak for a bit, then remain silent for ~1 second, then speak again.")
    print("Press Ctrl+C to stop.")
    
    recorder = AudioRecorder(silence_threshold=0.01, silence_duration=0.8)
    
    try:
        recorder.start(chunk_callback=test_callback)
        while True:
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\nStopping...")
        last_chunk = recorder.stop()
        if last_chunk is not None:
            print(f"[Test] Final chunk received! Size: {len(last_chunk)} samples ({len(last_chunk)/16000:.2f}s)")

if __name__ == "__main__":
    main()
