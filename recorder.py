import sounddevice as sd
import numpy as np
import threading
import queue
import time
from utils import play_sound

class AudioRecorder:
    def __init__(self, sample_rate=16000):
        self.sample_rate = sample_rate
        self.recording = False
        self.audio_data = []
        self.stream = None
        self._stop_event = threading.Event()
        self.device_id = self._find_builtin_device()

    def _find_builtin_device(self):
        """Searches for the built-in MacBook microphone."""
        devices = sd.query_devices()
        for i, dev in enumerate(devices):
            name = dev.get('name', '')
            # On macOS, internal mics usually have "MacBook" and "Microphone" in the name
            if 'MacBook' in name and 'Microphone' in name and dev.get('max_input_channels', 0) > 0:
                print(f"Forcing built-in microphone: {name} (ID: {i})")
                return i
        
        print("Warning: Built-in MacBook microphone not found. Using default device.")
        return None  # sounddevice uses default if None is passed

    def _callback(self, indata, frames, time_info, status):
        if status:
            print(f"Error in audio stream: {status}")
        if self.recording:
            self.audio_data.append(indata.copy())

    def start(self):
        if self.recording:
            return
        
        print(f"Starting recording on device {self.device_id if self.device_id is not None else 'default'}...")
        self.audio_data = []
        self.recording = True
        self._stop_event.clear()
        
        self.stream = sd.InputStream(
            device=self.device_id,
            samplerate=self.sample_rate,
            channels=1,
            callback=self._callback
        )
        self.stream.start()
        play_sound("/System/Library/Sounds/Tink.aiff")

    def stop(self):
        if not self.recording:
            return None
        
        print("Stopping recording...")
        self.recording = False
        if self.stream:
            self.stream.stop()
            self.stream.close()
        
        play_sound("/System/Library/Sounds/Pop.aiff")
        
        if not self.audio_data:
            return None
            
        # Concatenate all blocks and return as a single numpy array
        return np.concatenate(self.audio_data, axis=0).flatten()

if __name__ == "__main__":
    # Simple test
    recorder = AudioRecorder()
    recorder.start()
    time.sleep(3)
    data = recorder.stop()
    print(f"Recorded {len(data) / 16000:.2f} seconds of audio.")
