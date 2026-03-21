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
from .transcriber import TranscriberProcessWrapper
from .utils import (
    get_allowed_languages,
    get_primary_language,
    get_ui_strings,
    log_error,
    log_exception,
    log_info,
    save_config_to_disk,
    send_notification,
)


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
        self.transcriber = TranscriberProcessWrapper(
            model_name=self.config.get("model_name", "mlx-community/whisper-large-v3-turbo")
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

        # Jobs to run on the main thread (menu bar / rumps) so UI updates are applied
        self._main_thread_queue = queue.Queue()

    def start_model_warmup(self) -> None:
        """Start a background warm-up to reduce first-use latency."""
        if self.model_ready_event.is_set() or self._model_warming:
            return

        self._model_warming = True
        s = get_ui_strings(get_primary_language(self.config))
        send_notification("Click-n-speak", s["preparing_title"], s["preparing_body"])
        self._model_warmup_thread = threading.Thread(
            target=self._model_warmup_worker, daemon=True
        )
        self._model_warmup_thread.start()

    def _model_warmup_worker(self) -> None:
        try:
            log_info("Starting Whisper warm-up in background thread.")
            primary_lang = get_primary_language(self.config)
            self.transcriber.warmup(language=primary_lang)
            # Wait for warmup_done
            while True:
                try:
                    res = self.transcriber.output_queue.get(timeout=0.2)
                    if res["type"] == "warmup_done":
                        break
                    elif res["type"] == "error":
                        log_error(f"Warmup error: {res['message']}")
                        break
                except Exception:
                    # Ignore timeout and retry
                    pass
            log_info("Whisper warm-up finished.")
            s = get_ui_strings(get_primary_language(self.config))
            send_notification("Click-n-speak", s["model_ready_title"], s["model_ready_body"])
        except Exception as e:
            log_exception(f"Whisper warm-up failed: {e}")
            s = get_ui_strings(get_primary_language(self.config))
            send_notification("Click-n-speak", s["warmup_failed_title"], s["warmup_failed_body"])
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
                s = get_ui_strings(get_primary_language(self.config))
                send_notification("Click-n-speak", s["preparing_wait_title"], s["preparing_wait_body"])
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

    def _submit_for_main_thread(self, fn, *args, **kwargs) -> None:
        """Schedule fn(*args, **kwargs) to run on the main thread (drained by menu bar timer)."""
        self._main_thread_queue.put((fn, args, kwargs))

    def _do_finish_cleanup(self) -> None:
        """Run on main thread after worker has finished: clear status, save phrase, notify."""
        log_info("Finish cleanup started (main thread): clearing status, saving phrase, notifying.")
        self.is_processing = False
        if self._delayed_transcribing_timer is not None:
            try:
                self._delayed_transcribing_timer.cancel()
            except Exception:
                pass
            self._delayed_transcribing_timer = None
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
        s = get_ui_strings(get_primary_language(self.config))
        send_notification("Click-n-speak", s["ready_title"], s["ready_body"])
        log_info("Finish cleanup done. Ready for next recording session.")

    def _do_error_cleanup(self) -> None:
        """Run on main thread on stop_recording error: clear status, notify."""
        self.is_processing = False
        mb = self.menu_bar
        if mb is not None:
            try:
                mb.set_status(recording=False, processing=False)
            except Exception as e:
                log_error(f"Failed to set menu bar status: {e}")
        send_notification(
            "Click-n-speak",
            "Error",
            "An error occurred while finishing transcription. See log for details.",
        )

    def update_transcriber(self, model_name):
        log_info(f"Updating transcriber to {model_name}...")
        self.transcriber.update_model(model_name)
        self.transcriber.model_name = model_name

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
        if self.worker_thread is not None and self.worker_thread.is_alive():
            log_info("Previous chunk worker still running; cannot start new recording.")
            s = get_ui_strings(get_primary_language(self.config))
            send_notification(
                "Click-n-speak",
                s["still_working_title"],
                s["still_working_body"],
            )
            return
        log_info("Starting recording...")
        self.is_recording = True
        self._submit_for_main_thread(
            lambda: self.menu_bar.set_status(recording=True) if self.menu_bar else None
        )
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

        s = get_ui_strings(get_primary_language(self.config))
        send_notification("Click-n-speak", s["recording_title"], s["recording_body"])

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
            self._submit_for_main_thread(
                lambda: self.menu_bar.set_status(recording=False, processing=False)
                if self.menu_bar
                else None
            )
            send_notification(
                "Click-n-speak",
                "Error",
                "Could not start recording. See log for details.",
            )

    def on_chunk_received(self, audio_data):
        if self.is_recording:
            self.chunk_queue.put((audio_data, False))

    def chunk_worker(self):
        log_info("Chunk worker started.")
        while not self.stop_worker.is_set() or not self.chunk_queue.empty():
            try:
                audio_chunk, is_final_chunk = self.chunk_queue.get(timeout=0.5)
                remaining = self.chunk_queue.qsize()
                drain_note = (
                    " (draining queue after stop)"
                    if self.stop_worker.is_set()
                    else ""
                )
                log_info(
                    f"Chunk worker received audio chunk of length={len(audio_chunk)}, "
                    f"is_final={is_final_chunk}, chunks_remaining_in_queue={remaining}{drain_note}"
                )
                self.process_chunk(audio_chunk, is_final_chunk=is_final_chunk)
                self.chunk_queue.task_done()
            except queue.Empty:
                continue
            except Exception as e:
                log_exception(f"Error in chunk worker loop: {e}")
        log_info("Chunk worker stopped (queue empty, ready for next session).")

    def process_chunk(self, audio_chunk, is_final_chunk: bool = False):
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
                # Add a bilingual default prompt to prevent Whisper Large-v3 from auto-translating mixed languages
                default_prompt = "Текст содержит русские и английские слова. Mixed Russian and English terminology: API, bug, feature, survival."
                context = str(self.config.get("initial_prompt", "")) or default_prompt

            allowed_languages = get_allowed_languages(self.config)
            condition_on_previous_text = self.config.get(
                "condition_on_previous_text", True
            )

            log_info(
                "Processing audio chunk: "
                f"len={len(audio_chunk)}, "
                f"allowed_languages={allowed_languages}, "
                f"condition_on_previous_text={condition_on_previous_text}, "
                f"context_len={len(context)}"
                + (", is_final_chunk=True" if is_final_chunk else "")
            )

            text = self.transcriber.transcribe(
                audio_chunk,
                initial_prompt=context,
                allowed_languages=allowed_languages,
                condition_on_previous_text=condition_on_previous_text,
                is_final_chunk=is_final_chunk,
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
            self._submit_for_main_thread(
                lambda: self.menu_bar.set_status(recording=False, processing=True)
                if self.menu_bar
                else None
            )

            s = get_ui_strings(get_primary_language(self.config))
            send_notification("Click-n-speak", s["transcribing_title"], s["transcribing_body"])

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

            queue_size = self.chunk_queue.qsize()
            log_info(f"Chunk queue size at stop: {queue_size} (worker will finish queue)")

            if last_audio is not None and len(last_audio) > 0:
                self.chunk_queue.put((last_audio, True))
                log_info(
                    "Final audio chunk added to queue (worker will process it in order)."
                )

            # Signal worker to finish and wait for it (long timeout so "Finish" only after real completion)
            self.stop_worker.set()
            wait_start = time.time()

            # Schedule a delayed "still working" notification if recognition is slow if recognition is slow
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
                        s = get_ui_strings(get_primary_language(self.config))
                        send_notification(
                            "Click-n-speak",
                            s["still_working_title"],
                            s["still_working_body"],
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
                    self.worker_thread.join(timeout=120)
                except Exception as e:
                    log_exception(f"Error while joining worker_thread: {e}")
                waited = time.time() - wait_start
                if self.worker_thread.is_alive():
                    log_error(
                        f"Worker thread did not finish within timeout. "
                        f"Waited {waited:.1f}s. Submitting cleanup anyway."
                    )
                else:
                    log_info(
                        f"Worker thread finished. Waited {waited:.1f}s. "
                        "Submitting finish cleanup to main thread."
                    )

            # All UI updates and "Finish" run on main thread so menu bar actually updates
            self._submit_for_main_thread(self._do_finish_cleanup)
            log_info("Stop-recording phase done (cleanup scheduled on main thread).")
        except Exception as e:
            log_exception(f"Unhandled exception in stop_recording_and_process: {e}")
            self._submit_for_main_thread(self._do_error_cleanup)

    def stop(self):
        self.stop_worker.set()
        if self.worker_thread is not None and self.worker_thread.is_alive():
            self.worker_thread.join()
        if self.hotkey_handler:
            self.hotkey_handler.stop()
        if hasattr(self, "transcriber"):
            self.transcriber.stop()
