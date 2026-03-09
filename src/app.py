import json
import os
import threading
import time
import queue
from .recorder import AudioRecorder
from .transcriber import WhisperTranscriber
from .hotkey_handler import HotkeyHandler
from .injector import inject_text
from .utils import send_notification

class SVoiceRecApp:
    def __init__(self, config_path="config.json"):
        self.config = {} # Initialize to avoid lint errors
        self.load_config(config_path)
        self.recorder = AudioRecorder(
            sample_rate=self.config.get('sample_rate', 16000),
            device_id=self.config.get('device_id'),
            silence_threshold=self.config.get('silence_threshold', 0.01),
            silence_duration=self.config.get('silence_duration', 1.0),
            target_speech_duration=self.config.get('target_speech_duration', 8.0),
            max_speech_duration=self.config.get('max_speech_duration', 12.0)
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
        
        # Streaming state
        self.chunk_queue = queue.Queue()
        self.transcribed_parts = []
        self.worker_thread: threading.Thread | None = None
        self.stop_worker = threading.Event()

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
        self.transcribed_parts = []
        self.stop_worker.clear()
        
        # Clear the queue just in case
        while not self.chunk_queue.empty():
            try:
                self.chunk_queue.get_nowait()
            except queue.Empty:
                break

        # Start worker thread for chunk processing
        self.worker_thread = threading.Thread(target=self.chunk_worker)
        if self.worker_thread:
            self.worker_thread.start()
        
        send_notification("Click-n-speak", "Recording...", "Speak now. Press the hotkey again to finish.")
        self.recorder.start(chunk_callback=self.on_chunk_received)

    def on_chunk_received(self, audio_data):
        if self.is_recording:
            self.chunk_queue.put(audio_data)

    def chunk_worker(self):
        print("Chunk worker started.")
        while not self.stop_worker.is_set() or not self.chunk_queue.empty():
            try:
                # Use a timeout to occasionally check the stop_worker event
                audio_chunk = self.chunk_queue.get(timeout=0.5)
                self.process_chunk(audio_chunk)
                self.chunk_queue.task_done()
            except queue.Empty:
                continue
            except Exception as e:
                print(f"Error in chunk worker: {e}")
        print("Chunk worker stopped.")

    def process_chunk(self, audio_chunk):
        # Determine initial prompt from previously transcribed text
        context = " ".join(self.transcribed_parts) if self.transcribed_parts else self.config.get('initial_prompt')
        
        text = self.transcriber.transcribe(
            audio_chunk,
            initial_prompt=context,
            condition_on_previous_text=self.config.get('condition_on_previous_text', True)
        )
        
        if text:
            print(f"Partial Transcription: {text}")
            self.transcribed_parts.append(text)
            # Inject partial text immediately
            inject_text(text + " ")

    def stop_recording_and_process(self):
        self.is_recording = False
        self.is_processing = True
        
        # Stop recording and get the last (remaining) chunk
        last_audio = self.recorder.stop()
        
        if last_audio is not None and len(last_audio) > 0:
            self.chunk_queue.put(last_audio)
        
        # Signal worker to finish and wait for it
        self.stop_worker.set()
        if self.worker_thread:
            self.worker_thread.join()
        
        # Cleanup
        self.is_processing = False
        send_notification("Click-n-speak", "Finish", "Transcription complete.")

    def stop(self):
        self.stop_worker.set()
        if self.worker_thread and self.worker_thread.is_alive():
            self.worker_thread.join()
        if self.hotkey_handler:
            self.hotkey_handler.stop()
