import json
import os
import threading
import time
import queue
from .recorder import AudioRecorder
from .transcriber import WhisperTranscriber
from .hotkey_handler import HotkeyHandler
from .injector import inject_text
from .utils import send_notification, log_info, log_error

class SVoiceRecApp:
    def __init__(self, config_path="config.json"):
        self.menu_bar = None # type: ignore
        self.config = {}
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
        self.worker_thread = None  # type: threading.Thread | None
        self.stop_worker = threading.Event()

    def load_config(self, path):
        if not os.path.exists(path):
            log_info(f"Warning: Configuration file {path} not found. Using defaults.")
            self.load_config_data({})
            return

        try:
            with open(path, 'r') as f:
                data = json.load(f)
                self.load_config_data(data)
        except Exception as e:
            log_error(f"Error loading config: {e}. Using defaults.")
            self.load_config_data({})

    def load_config_data(self, data):
        self.config = data
        if hasattr(self, 'recorder'):
            self.update_recorder_settings()
        if hasattr(self, 'transcriber'):
            model = self.config.get('model_name', 'mlx-community/whisper-large-v3-mlx')
            if self.transcriber.model_name != model:
                self.update_transcriber(model)

    def update_config(self, updates):
        """Update config with a dict of key-value pairs, save and reload."""
        self.config.update(updates)
        self.load_config_data(self.config)
        # Persist to disk
        try:
            config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'config.json')
            with open(config_path, 'w') as f:
                import json as _json
                _json.dump(self.config, f, indent=4)
        except Exception as e:
            log_error(f"Error saving config: {e}")

    def toggle_recording(self):
        current_time = time.time()
        if current_time - self.last_toggle_time < self.debounce_interval:
            log_info("Ignoring hotkey: debounce interval not met.")
            return
        
        self.last_toggle_time = current_time

        if self.is_processing:
            log_info("Still processing previous recording. Please wait.")
            return

        if not self.is_recording:
            self.start_recording()
        else:
            self.stop_recording_and_process()

    def set_menu_bar(self, menu_bar):
        self.menu_bar = menu_bar

    def update_transcriber(self, model_name):
        log_info(f"Updating transcriber to {model_name}...")
        self.transcriber = WhisperTranscriber(model_name=model_name)

    def update_recorder_settings(self, **kwargs):
        # Override config with any specifically provided kwargs first
        for k, v in kwargs.items():
            self.config[k] = v
            
        if hasattr(self, 'recorder'):
            self.recorder.silence_threshold = self.config.get('silence_threshold', 0.01)
            self.recorder.silence_duration = self.config.get('silence_duration', 1.0)
            self.recorder.target_speech_duration = self.config.get('target_speech_duration', 8.0)
            self.recorder.max_speech_duration = self.config.get('max_speech_duration', 12.0)
            log_info("Recorder settings updated.")

    def start_recording(self):
        self.is_recording = True
        mb = self.menu_bar
        if mb is not None:
            try:
                mb.set_status(recording=True)
            except Exception:
                pass
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
        log_info("Chunk worker started.")
        while not self.stop_worker.is_set() or not self.chunk_queue.empty():
            try:
                # Use a timeout to occasionally check the stop_worker event
                audio_chunk = self.chunk_queue.get(timeout=0.5)
                self.process_chunk(audio_chunk)
                self.chunk_queue.task_done()
            except queue.Empty:
                continue
            except Exception as e:
                log_error(f"Error in chunk worker: {e}")
        log_info("Chunk worker stopped.")

    def process_chunk(self, audio_chunk):
        # Determine initial prompt from previously transcribed text (limit context to prevent drift)
        if self.transcribed_parts:
            full_context = " ".join(self.transcribed_parts)
            # Use string methods to avoid indexing issues with some linters
            if len(full_context) > 200:
                context = full_context[-200:] # type: ignore
            else:
                context = full_context
        else:
            context = str(self.config.get('initial_prompt', ''))
        
        text = self.transcriber.transcribe(
            audio_chunk,
            initial_prompt=context,
            allowed_languages=self.config.get('languages', []),
            condition_on_previous_text=self.config.get('condition_on_previous_text', True)
        )
        
        if text:
            log_info(f"Partial Transcription: {text}")
            self.transcribed_parts.append(text)
            # Keep parts manageable
            if len(self.transcribed_parts) > 10:
                self.transcribed_parts.pop(0)
            # Inject partial text immediately
            inject_text(text + " ")
            
    def stop_recording_and_process(self):
        self.is_recording = False
        self.is_processing = True
        mb = self.menu_bar
        if mb is not None:
            mb.set_status(recording=False, processing=True)
        
        # Stop recording and get the last (remaining) chunk
        last_audio = self.recorder.stop()
        
        if last_audio is not None and len(last_audio) > 0:
            self.chunk_queue.put(last_audio)
        
        # Signal worker to finish and wait for it
        self.stop_worker.set()
        if self.worker_thread is not None:
            self.worker_thread.join()
        
        # Cleanup
        self.is_processing = False
        mb = self.menu_bar
        if mb is not None:
            mb.set_status(recording=False, processing=False)
        send_notification("Click-n-speak", "Finish", "Transcription complete.")

    def stop(self):
        self.stop_worker.set()
        if self.worker_thread is not None and self.worker_thread.is_alive():
            self.worker_thread.join()
        if self.hotkey_handler:
            self.hotkey_handler.stop()
