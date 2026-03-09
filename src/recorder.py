import sounddevice as sd
import numpy as np
import threading
import time
from .utils import play_sound

class AudioRecorder:
    def __init__(self, sample_rate=16000, device_id=None):
        self.sample_rate = sample_rate
        self.recording = False
        self.audio_data = []
        self.stream = None
        self._stop_event = threading.Event()
        
        # If device_id is provided in config, use it. Otherwise, try to find built-in.
        if device_id is not None:
            self.device_id = device_id
        else:
            self.device_id = self._find_builtin_device()

    def _find_builtin_device(self):
        """Searches for the built-in MacBook microphone."""
        try:
            devices = sd.query_devices()
            for i, dev in enumerate(devices):
                name = dev.get('name', '')
                # On macOS, internal mics usually have "MacBook" and "Microphone" in the name
                if 'MacBook' in name and 'Microphone' in name and dev.get('max_input_channels', 0) > 0:
                    print(f"Found built-in microphone: {name} (ID: {i})")
                    return i
        except Exception as e:
            print(f"Error querying audio devices: {e}")
        
        # If not found or error, return None to use system default
        return None

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
        
        try:
            self.stream = sd.InputStream(
                device=self.device_id,
                samplerate=self.sample_rate,
                channels=1,
                callback=self._callback
            )
            self.stream.start()
            play_sound("/System/Library/Sounds/Tink.aiff")
        except Exception as e:
            print(f"Could not start audio stream: {e}")
            self.recording = False

    def stop(self):
        if not self.recording:
            return None
        
        print("Stopping recording...")
        self.recording = False
        if self.stream:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception as e:
                print(f"Error closing audio stream: {e}")
        
        play_sound("/System/Library/Sounds/Pop.aiff")
        
        if not self.audio_data:
            return None
            
        # Concatenate all blocks and return as a single numpy array
        return np.concatenate(self.audio_data, axis=0).flatten()
