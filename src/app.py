import json
import os
import queue
import threading
import time
from typing import Optional

from .hotkey_handler import HotkeyHandler
from .injector import inject_text
from .phrase_history import append_phrase
from .recorder import AudioRecorder
from .transcriber import WhisperTranscriber
from .utils import log_error, log_exception, log_info, save_config_to_disk, send_notification


class SVoiceRecApp:
    def __init__(self, config_path="config.json"):
        self.menu_bar = None  # type: ignore
        self.config = {}
        self.load_config(config_path)
        self.recorder = AudioRecorder(
            sample_rate=self.config.get("sample_rate", 16000),
            device_id=self.config.get("device_id"),
            silence_threshold=self.config.get("silence_threshold", 0.01),
            silence_duration=self.config.get("silence_duration", 1.0),
            target_speech_duration=self.config.get("target_speech_duration", 8.0),
            max_speech_duration=self.config.get("max_speech_duration", 12.0),
        )
        self.transcriber = WhisperTranscriber(
            model_name=self.config.get("model_name", "mlx-community/whisper-large-v3-mlx")
        )
        self.hotkey_handler = HotkeyHandler(
            hotkey_str=self.config.get("hotkey", "<alt>+<space>"), on_trigger=self.toggle_recording
        )
        self.is_recording = False
        self.is_processing = False
        self.last_toggle_time = 0.0
        self.debounce_interval = 0.3  # seconds

        # Streaming state
        self.chunk_queue = queue.Queue()
        self.transcribed_parts = []
        self.worker_thread = None  # type: threading.Thread | None
        self.stop_worker = threading.Event()

        # Model warm-up state (cold-start optimization after app rebuild/restart)
        self._model_warming = False
        self.model_ready_event = threading.Event()
        self._model_warmup_thread: Optional[threading.Thread] = None

        # Delayed notification while waiting for transcription to finish
        self._transcription_cycle_id = 0
        self._delayed_transcribing_timer: Optional[threading.Timer] = None
        self._still_working_delay_seconds = 12.0

    def start_model_warmup(self) -> None:
        """Start a background warm-up to reduce first-use latency."""
        if self.model_ready_event.is_set() or self._model_warming:
            return

        self._model_warming = True
        send_notification(
            "Click-n-speak",
            "Подготовка модели...",
            "Загружаю/скачиваю Whisper-модель. Первый запуск может занять время.",
        )
        self._model_warmup_thread = threading.Thread(
            target=self._model_warmup_worker, daemon=True
        )
        self._model_warmup_thread.start()

    def _model_warmup_worker(self) -> None:
        try:
            log_info("Starting Whisper warm-up in background thread.")
            self.transcriber.warmup()
            log_info("Whisper warm-up finished.")
            send_notification(
                "Click-n-speak",
                "Модель готова",
                "Можно начинать диктовку.",
            )
        except Exception as e:
            log_exception(f"Whisper warm-up failed: {e}")
            send_notification(
                "Click-n-speak",
                "Подготовка модели не удалась",
                "Запись продолжит работать, но первый распознающий запрос может быть медленнее.",
            )
        finally:
            self.model_ready_event.set()
            self._model_warming = False

    def load_config(self, path):
        if not os.path.exists(path):
            log_info(f"Warning: Configuration file {path} not found. Using defaults.")
            self.load_config_data({})
            return

        try:
            with open(path, "r") as f:
                data = json.load(f)
                self.load_config_data(data)
        except Exception as e:
            log_error(f"Error loading config: {e}. Using defaults.")
            self.load_config_data({})

    def load_config_data(self, data):
        self.config = data
        if hasattr(self, "recorder"):
            self.update_recorder_settings()
        if hasattr(self, "transcriber"):
            model = self.config.get("model_name", "mlx-community/whisper-large-v3-mlx")
            if self.transcriber.model_name != model:
                self.update_transcriber(model)

    def update_config(self, updates):
        """Update config with a dict of key-value pairs, save and reload."""
        self.config.update(updates)
        self.load_config_data(self.config)
        save_config_to_disk(self.config)

    def toggle_recording(self):
        """Hotkey callback: toggles recording state with debounce and safety logging."""
        try:
            current_time = time.time()
            if current_time - self.last_toggle_time < self.debounce_interval:
                log_info("Ignoring hotkey: debounce interval not met.")
                return

            self.last_toggle_time = current_time

            log_info(
                f"Hotkey pressed. is_recording={self.is_recording}, "
                f"is_processing={self.is_processing}"
            )

            if self.is_processing:
                log_info("Still processing previous recording. Please wait.")
                return

            # Do not start a new recording cycle while warm-up is in progress.
            if (
                not self.is_recording
                and self._model_warming
                and not self.model_ready_event.is_set()
            ):
                log_info("Ignoring hotkey: model warm-up in progress.")
                send_notification(
                    "Click-n-speak",
                    "Подготовка модели...",
                    "Подождите несколько секунд и попробуйте снова.",
                )
                return

            if not self.is_recording:
                self.start_recording()
            else:
                self.stop_recording_and_process()
        except Exception as e:
            # Catch-all to avoid crashing the app from the hotkey thread
            log_exception(f"Unhandled exception in toggle_recording: {e}")

    def set_menu_bar(self, menu_bar):
        self.menu_bar = menu_bar

    def update_transcriber(self, model_name):
        log_info(f"Updating transcriber to {model_name}...")
        self.transcriber = WhisperTranscriber(model_name=model_name)

    def update_recorder_settings(self, **kwargs):
        # Override config with any specifically provided kwargs first
        for k, v in kwargs.items():
            self.config[k] = v

        if hasattr(self, "recorder"):
            self.recorder.silence_threshold = self.config.get("silence_threshold", 0.01)
            self.recorder.silence_duration = self.config.get("silence_duration", 1.0)
            self.recorder.target_speech_duration = self.config.get("target_speech_duration", 8.0)
            self.recorder.max_speech_duration = self.config.get("max_speech_duration", 12.0)
            log_info("Recorder settings updated.")

    def start_recording(self):
        log_info("Starting recording...")
        self.is_recording = True
        mb = self.menu_bar
        if mb is not None:
            try:
                mb.set_status(recording=True)
            except Exception as e:
                log_error(f"Failed to set menu bar status: {e}")
        self.transcribed_parts = []
        self.stop_worker.clear()

        # Clear the queue just in case
        cleared = 0
        while not self.chunk_queue.empty():
            try:
                self.chunk_queue.get_nowait()
                cleared += 1
            except queue.Empty:
                break
        if cleared:
            log_info(f"Cleared {cleared} pending audio chunks before starting.")

        # Start worker thread for chunk processing
        self.worker_thread = threading.Thread(target=self.chunk_worker)
        if self.worker_thread:
            log_info("Starting chunk worker thread.")
            self.worker_thread.start()

        send_notification(
            "Click-n-speak",
            "Запись...",
            "Говорите. Нажмите горячую клавишу ещё раз, чтобы остановить.",
        )

        try:
            self.recorder.start(chunk_callback=self.on_chunk_received)
            log_info(
                "AudioRecorder started with settings: "
                f"sample_rate={self.recorder.sample_rate}, "
                f"silence_threshold={self.recorder.silence_threshold}, "
                f"silence_duration={self.recorder.silence_duration}, "
                f"target_speech_duration={self.recorder.target_speech_duration}, "
                f"max_speech_duration={self.recorder.max_speech_duration}"
            )
        except Exception as e:
            self.is_recording = False
            log_exception(f"Failed to start AudioRecorder: {e}")
            mb = self.menu_bar
            if mb is not None:
                try:
                    mb.set_status(recording=False, processing=False)
                except Exception as err:
                    log_error(f"Failed to reset menu bar status after recorder error: {err}")
            send_notification(
                "Click-n-speak",
                "Error",
                "Could not start recording. See log for details.",
            )

    def on_chunk_received(self, audio_data):
        if self.is_recording:
            self.chunk_queue.put(audio_data)

    def chunk_worker(self):
        log_info("Chunk worker started.")
        while not self.stop_worker.is_set() or not self.chunk_queue.empty():
            try:
                # Use a timeout to occasionally check the stop_worker event
                audio_chunk = self.chunk_queue.get(timeout=0.5)
                log_info(
                    f"Chunk worker received audio chunk of length={len(audio_chunk)}"
                )
                self.process_chunk(audio_chunk)
                self.chunk_queue.task_done()
            except queue.Empty:
                continue
            except Exception as e:
                # Any unhandled exception here could silently kill the worker;
                # log full traceback to diagnose rare crashes.
                log_exception(f"Error in chunk worker loop: {e}")
        log_info("Chunk worker stopped.")

    def process_chunk(self, audio_chunk):
        """Transcribe a single audio chunk and inject text; heavily logged for debugging."""
        try:
            # Determine initial prompt from previously transcribed text (limit context to prevent drift)
            if self.transcribed_parts:
                full_context = " ".join(self.transcribed_parts)
                # Use string methods to avoid indexing issues with some linters
                if len(full_context) > 200:
                    context = full_context[-200:]  # type: ignore
                else:
                    context = full_context
            else:
                context = str(self.config.get("initial_prompt", ""))

            allowed_languages = self.config.get("languages", [])
            condition_on_previous_text = self.config.get(
                "condition_on_previous_text", True
            )

            log_info(
                "Processing audio chunk: "
                f"len={len(audio_chunk)}, "
                f"allowed_languages={allowed_languages}, "
                f"condition_on_previous_text={condition_on_previous_text}, "
                f"context_len={len(context)}"
            )

            text = self.transcriber.transcribe(
                audio_chunk,
                initial_prompt=context,
                allowed_languages=allowed_languages,
                condition_on_previous_text=condition_on_previous_text,
            )

            if text:
                log_info(f"Partial Transcription: {text}")
                self.transcribed_parts.append(text)
                # Keep parts manageable
                if len(self.transcribed_parts) > 10:
                    self.transcribed_parts.pop(0)
                # Inject partial text immediately
                inject_text(text + " ")
            else:
                log_info("Transcriber returned empty text for this chunk.")
        except Exception as e:
            log_exception(f"Unhandled exception in process_chunk: {e}")

    def stop_recording_and_process(self):
        log_info("Stopping recording and finalizing transcription...")
        try:
            self.is_recording = False
            self.is_processing = True
            mb = self.menu_bar
            if mb is not None:
                try:
                    mb.set_status(recording=False, processing=True)
                except Exception as e:
                    log_error(f"Failed to set menu bar status: {e}")

            send_notification(
                "Click-n-speak",
                "Распознаю...",
                "Идёт распознавание речи. Подождите.",
            )

            # Stop recording and get the last (remaining) chunk
            try:
                last_audio = self.recorder.stop()
                if last_audio is None:
                    log_info("Recorder.stop() returned None (no final audio chunk).")
                else:
                    log_info(f"Recorder.stop() returned final chunk len={len(last_audio)}.")
            except Exception as e:
                last_audio = None
                log_exception(f"Error during recorder.stop(): {e}")

            if last_audio is not None and len(last_audio) > 0:
                self.chunk_queue.put(last_audio)
                log_info("Final audio chunk enqueued for processing.")

            # Signal worker to finish and wait for it
            self.stop_worker.set()

            # Schedule a delayed "still working" notification if recognition is slow.
            self._transcription_cycle_id += 1
            cycle_id = self._transcription_cycle_id

            if self._delayed_transcribing_timer is not None:
                try:
                    self._delayed_transcribing_timer.cancel()
                except Exception:
                    pass

            def _delayed_notify() -> None:
                try:
                    if self._transcription_cycle_id != cycle_id:
                        return
                    if self.worker_thread is not None and self.worker_thread.is_alive():
                        send_notification(
                            "Click-n-speak",
                            "Распознаю... всё ещё идёт",
                            "Распознавание ещё выполняется. Подождите.",
                        )
                except Exception as e:
                    log_exception(f"Delayed transcription notify failed: {e}")

            self._delayed_transcribing_timer = threading.Timer(
                self._still_working_delay_seconds, _delayed_notify
            )
            self._delayed_transcribing_timer.daemon = True
            self._delayed_transcribing_timer.start()

            if self.worker_thread is not None:
                log_info("Waiting for chunk worker thread to finish...")
                try:
                    self.worker_thread.join(timeout=30)
                except Exception as e:
                    log_exception(f"Error while joining worker_thread: {e}")
                if self.worker_thread.is_alive():
                    log_error("Worker thread did not finish within timeout.")

            # Cleanup
            self.is_processing = False
            if self._delayed_transcribing_timer is not None:
                try:
                    self._delayed_transcribing_timer.cancel()
                except Exception:
                    pass
            mb = self.menu_bar
            if mb is not None:
                try:
                    mb.set_status(recording=False, processing=False)
                except Exception as e:
                    log_error(f"Failed to set menu bar status: {e}")

            full_phrase = " ".join(self.transcribed_parts).strip()
            if full_phrase:
                append_phrase(full_phrase)
                if mb is not None and hasattr(mb, "refresh_last_phrases_submenu"):
                    try:
                        mb.refresh_last_phrases_submenu()
                    except Exception as e:
                        log_error(f"Failed to refresh Last 5 phrases submenu: {e}")

            send_notification(
                "Click-n-speak",
                "Готово",
                "Распознавание завершено. Можно диктовать снова.",
            )
        except Exception as e:
            self.is_processing = False
            log_exception(f"Unhandled exception in stop_recording_and_process: {e}")
            mb = self.menu_bar
            if mb is not None:
                try:
                    mb.set_status(recording=False, processing=False)
                except Exception as err:
                    log_error(
                        f"Failed to reset menu bar status after stop error: {err}"
                    )
            send_notification(
                "Click-n-speak",
                "Error",
                "An error occurred while finishing transcription. See log for details.",
            )

    def stop(self):
        self.stop_worker.set()
        if self.worker_thread is not None and self.worker_thread.is_alive():
            self.worker_thread.join()
        if self.hotkey_handler:
            self.hotkey_handler.stop()
