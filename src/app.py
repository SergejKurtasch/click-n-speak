import json
import os
import threading
import time
from .recorder import AudioRecorder
from .transcriber import WhisperTranscriber
from .hotkey_handler import HotkeyHandler
from .injector import inject_text
from .utils import send_notification

class SVoiceRecApp:
    def __init__(self, config_path="config.json"):
        self.load_config(config_path)
        self.recorder = AudioRecorder(
            sample_rate=self.config.get('sample_rate', 16000),
            device_id=self.config.get('device_id')
        )
        self.transcriber = WhisperTranscriber(model_name=self.config.get('model_name', 'mlx-community/whisper-large-v3-mlx'))
        self.hotkey_handler = HotkeyHandler(
            hotkey_str=self.config.get('hotkey', '<alt>+<space>'),
            on_trigger=self.toggle_recording
        )
        self.is_recording = False
        self.is_processing = False
        self.last_toggle_time = 0.0
        self.debounce_interval = 0.3 # seconds

    def load_config(self, path):
        if not os.path.exists(path):
            print(f"Warning: Configuration file {path} not found. Using defaults.")
            self.config = {}
            return

        try:
            with open(path, 'r') as f:
                self.config = json.load(f)
        except Exception as e:
            print(f"Error loading config: {e}. Using defaults.")
            self.config = {}

    def toggle_recording(self):
        current_time = time.time()
        if current_time - self.last_toggle_time < self.debounce_interval:
            print("Ignoring hotkey: debounce interval not met.")
            return
        
        self.last_toggle_time = current_time

        if self.is_processing:
            print("Still processing previous recording. Please wait.")
            return

        if not self.is_recording:
            self.start_recording()
        else:
            self.stop_recording_and_process()

    def start_recording(self):
        self.is_recording = True
        send_notification("Click-n-speak", "Recording...", "Speak now. Press the hotkey again to finish.")
        self.recorder.start()

    def stop_recording_and_process(self):
        self.is_recording = False
        self.is_processing = True
        
        audio_data = self.recorder.stop()
        if audio_data is None or len(audio_data) == 0:
            print("No audio recorded.")
            send_notification("Click-n-speak", "Finish", "No audio recorded.")
            self.is_processing = False
            return

        # Run transcription in a separate thread to not block the hotkey handler
        threading.Thread(target=self.process_audio, args=(audio_data,)).start()

    def process_audio(self, audio_data):
        try:
            send_notification("Click-n-speak", "Processing...", "Transcribing your speech.")
            
            text = self.transcriber.transcribe(
                audio_data, 
                initial_prompt=self.config.get('initial_prompt'),
                condition_on_previous_text=self.config.get('condition_on_previous_text', True)
            )
            
            if text:
                print(f"Transcribed Text: {text}")
                inject_text(text)
                send_notification("Click-n-speak", "Success", "Text injected successfully.")
            else:
                send_notification("Click-n-speak", "Finish", "Could not transcribe audio.")
                
        except Exception as e:
            print(f"Error during processing: {e}")
            send_notification("Click-n-speak", "Error", f"Failed to process audio: {str(e)}")
        finally:
            self.is_processing = False

    def stop(self):
        if self.hotkey_handler:
            self.hotkey_handler.stop()
