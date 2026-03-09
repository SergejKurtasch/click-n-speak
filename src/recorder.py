import sounddevice as sd
import numpy as np
import threading
import time
from .utils import play_sound

class AudioRecorder:
    def __init__(self, sample_rate=16000, device_id=None, silence_threshold=0.01, silence_duration=1.0, 
                 target_speech_duration=8.0, max_speech_duration=12.0):
        self.sample_rate = sample_rate
        self.recording = False
        self.audio_data = [] # Current chunk data
        self.stream = None
        self._stop_event = threading.Event()
        
        # Silence detection parameters
        self.silence_threshold = silence_threshold
        self.silence_duration = silence_duration # Normal pause
        self.target_speech_duration = target_speech_duration # Start looking for micro-pauses
        self.max_speech_duration = max_speech_duration # Force split
        
        self.silence_counter = 0
        self.chunk_callback = None
        self.has_speech_in_chunk = False
        self.current_chunk_duration = 0 # Track time since last split
        
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
        
        if not self.recording:
            return

        # Append data to current chunk
        self.audio_data.append(indata.copy())

        # Check for silence
        # RMS energy
        energy = np.sqrt(np.mean(indata**2))
        
        # Update current chunk duration
        chunk_increment = frames / self.sample_rate
        self.current_chunk_duration += chunk_increment

        if energy < self.silence_threshold:
            self.silence_counter += chunk_increment
        else:
            self.silence_counter = 0
            self.has_speech_in_chunk = True

        # Adaptive silence threshold:
        # 1. Normal: 1.0s (default)
        # 2. After target_speech_duration: 0.4s (micro-pause)
        # 3. After max_speech_duration: 0s (force split)
        
        effective_silence_duration = self.silence_duration
        trigger_type = "Normal"
        
        if self.current_chunk_duration >= self.max_speech_duration:
            effective_silence_duration = 0 # Force split immediately
            trigger_type = "FORCE (Max duration)"
        elif self.current_chunk_duration >= self.target_speech_duration:
            effective_silence_duration = 0.4 # Micro-pause threshold
            trigger_type = "MICRO (Target duration)"

        # If silence duration exceeded and we have some audio, trigger chunk callback
        if self.silence_counter >= effective_silence_duration:
            if len(self.audio_data) > 0 and self.has_speech_in_chunk:
                duration = sum(len(x) for x in self.audio_data) / self.sample_rate
                if duration > 0.5:
                    print(f"Triggering {trigger_type} chunk: {self.current_chunk_duration:.2f}s total, {self.silence_counter:.2f}s silence")
                    self._trigger_chunk()
            
            # Reset chunk state even if it was just noise
            self.audio_data = []
            self.silence_counter = 0
            self.has_speech_in_chunk = False
            self.current_chunk_duration = 0

    def _trigger_chunk(self):
        if not self.audio_data:
            return
            
        chunk = np.concatenate(self.audio_data, axis=0).flatten()
        
        if self.chunk_callback:
            # Run callback in a separate thread to not block the audio stream
            threading.Thread(target=self.chunk_callback, args=(chunk,), daemon=True).start()

    def start(self, chunk_callback=None):
        if self.recording:
            return
        
        print(f"Starting recording on device {self.device_id if self.device_id is not None else 'default'}...")
        self.audio_data = []
        self.recording = True
        self.chunk_callback = chunk_callback
        self.silence_counter = 0
        self.has_speech_in_chunk = False
        self.current_chunk_duration = 0
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
