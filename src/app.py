import json
import queue
import threading
import time
from pathlib import Path
from typing import Optional

from .hotkey_handler import HotkeyHandler
from .injector import inject_text
from .phrase_history import append_phrase
from .recorder import AudioRecorder
try:
    from AppKit import NSWorkspace, NSRunningApplication
except ImportError:
    NSWorkspace = None
    NSRunningApplication = None

from .dataset_logger import append_to_dataset
from .ai_editor import AiEditor, DEFAULT_MODEL_NAME
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

# Keep-alive interval in seconds (15 minutes)
KEEP_ALIVE_INTERVAL_SECONDS = 15 * 60
# Memory pressure threshold (%) above which keep-alive is disabled
MEMORY_PRESSURE_THRESHOLD_PERCENT = 75


class SVoiceRecApp:
    def __init__(self, config_path="config.json"):
        self.menu_bar = None  # type: ignore
        self.config = {}
        self.load_config(config_path)
        self.recorder = AudioRecorder(
            sample_rate=self.config.get("sample_rate", 16000),
            device_id=self.config.get("device_id"),
            silence_threshold=self.config.get("silence_threshold", 0.01),
            silence_duration=self.config.get("silence_duration", 0.5),
            target_speech_duration=self.config.get("target_speech_duration", 4.0),
            max_speech_duration=self.config.get("max_speech_duration", 8.0),
            min_speech_duration=self.config.get("min_speech_duration", 0.5),
        )
        self.transcriber = TranscriberProcessWrapper(
            model_name=self.config.get("model_name", "mlx-community/whisper-large-v3-turbo")
        )
        # AI Editor: optional LLM post-processing for punctuation and cleanup
        self.ai_editor: Optional[AiEditor] = None
        self._ai_editor_loading = False
        self._ai_editor_lock = threading.Lock()  # guards _ai_editor_loading read/write
        if self.config.get("ai_editor_enabled", False):
            self._init_ai_editor()
        self.hotkey_handler = HotkeyHandler(
            hotkey_str=self.config.get("hotkey", "<alt>+<space>"), on_trigger=self.toggle_recording
        )
        self.is_recording = False
        self.is_processing = False
        self.last_toggle_time = 0.0
        self.debounce_interval = 0.3  # seconds

        # Streaming state
        self.chunk_queue = queue.Queue(maxsize=30)  # ~4 min of 8s chunks; prevents unbounded growth if transcriber hangs
        self.transcribed_parts = []
        self.worker_thread = None  # type: threading.Thread | None
        self.stop_worker = threading.Event()
        # Session ID incremented on each new recording; workers capture it at start
        # and skip injection if the ID no longer matches (new session started).
        self._session_id = 0

        # Model warm-up state (cold-start optimization after app rebuild/restart)
        self._model_warming = False
        self.model_ready_event = threading.Event()
        self._model_warmup_thread: Optional[threading.Thread] = None

        # Delayed notification while waiting for transcription to finish.
        # _timer_lock guards all reads/writes of _delayed_transcribing_timer because
        # stop_recording_and_process (background thread) and _do_finish_cleanup (main
        # thread) both access it; without a lock the cancel can race with creation.
        self._transcription_cycle_id = 0
        self._delayed_transcribing_timer: Optional[threading.Timer] = None
        self._timer_lock = threading.Lock()
        self._still_working_delay_seconds = 12.0

        # Jobs to run on the main thread (menu bar / rumps) so UI updates are applied
        self._main_thread_queue = queue.Queue()

        # Keep-alive & cold-start optimization
        self._last_transcription_time = time.time()  # Initialized to now (warmup counts)
        self._keep_alive_timer: Optional[threading.Timer] = None
        self._keep_alive_lock = threading.Lock()  # atomic guard for keep-alive warmup
        self._wake_observer = None  # macOS wake observer (set in start_wake_observer)
        self._preview_panel = None  # lazy-init on first use
        self._previous_app_pid = None
        self._raw_whisper_text = ""
        self._raw_whisper_chunks = []  # raw Whisper output per chunk, before AI editing
        self._ai_edited_text = None

    def _ensure_preview_panel(self):
        if self._preview_panel is None:
            from .preview_panel import TranscriptionPreviewPanel
            self._preview_panel = TranscriptionPreviewPanel()

    def _init_ai_editor(self) -> None:
        """Create and load the AiEditor in a background thread (non-blocking)."""
        with self._ai_editor_lock:
            if self._ai_editor_loading:
                return
            model_name = self.config.get("ai_editor_model", DEFAULT_MODEL_NAME)
            self.ai_editor = AiEditor(model_name=model_name)
            self._ai_editor_loading = True
        threading.Thread(target=self._ai_editor_load_worker, daemon=True).start()

    def _ai_editor_load_worker(self) -> None:
        """Background worker: load the LLM model and notify when ready."""
        try:
            # Capture a local reference so that update_config() setting
            # self.ai_editor = None mid-load does not cause AttributeError.
            editor = self.ai_editor
            if editor is None:
                return

            # Check cache BEFORE trying to load — prevents silent multi-hour downloads
            if not editor.is_model_cached():
                log_error(
                    f"AiEditor: model '{editor.model_name}' is not cached locally. "
                    "Download it first by running in your terminal:\n"
                    "  python scripts/download_ai_model.py"
                )
                self.notify("AI Editor: Модель не найдена", "Запустите скрипт загрузки и перезапустите приложение.")
                return

            editor.load()
            # Guard: user may have disabled AI Editor while load() was running
            if self.ai_editor is None:
                log_info("AiEditor was disabled during load — discarding.")
                return
            if editor.is_ready():
                self.notify("AI Editor Готов", "Умная пунктуация и очистка текста активированы.")
                log_info("AiEditor loaded and ready.")
            else:
                log_error("AiEditor failed to load — editor will be skipped.")
                self.notify("AI Editor: Ошибка загрузки", "Не удалось загрузить модель. Проверьте логи.")
        except Exception as e:
            log_exception(f"AiEditor background load failed: {e}")
        finally:
            with self._ai_editor_lock:
                self._ai_editor_loading = False

    def start_model_warmup(self) -> None:
        """Start a background warm-up to reduce first-use latency."""
        if self.model_ready_event.is_set() or self._model_warming:
            return

        self._model_warming = True
        s = get_ui_strings(get_primary_language(self.config))
        self._ensure_preview_panel()
        self._preview_panel.show(s["preparing_title"], self._main_thread_queue)
        self._model_warmup_thread = threading.Thread(
            target=self._model_warmup_worker, daemon=True
        )
        self._model_warmup_thread.start()

    def _model_warmup_worker(self) -> None:
        try:
            log_info("Starting Whisper warm-up in background thread.")
            primary_lang = get_primary_language(self.config)
            self.transcriber.warmup(language=primary_lang)
            # Wait for warmup_done with a hard deadline so a crashed child process
            # does not leave _model_warming=True and permanently block all recordings.
            deadline = time.monotonic() + 60.0
            while time.monotonic() < deadline:
                try:
                    res = self.transcriber.output_queue.get(timeout=0.5)
                    if res["type"] == "warmup_done":
                        break
                    elif res["type"] == "error":
                        log_error(f"Warmup error: {res['message']}")
                        break
                except queue.Empty:
                    continue
            else:
                log_error("Warmup timed out after 60s — child process may have crashed.")
            log_info("Whisper warm-up finished.")
            s = get_ui_strings(get_primary_language(self.config))
            if self._preview_panel:
                self._preview_panel.update_status(s["model_ready_title"], self._main_thread_queue)
                self._preview_panel.hide(self._main_thread_queue, delay=1.5)
        except Exception as e:
            log_exception(f"Whisper warm-up failed: {e}")
            s = get_ui_strings(get_primary_language(self.config))
            if self._preview_panel:
                self._preview_panel.update_status(s["warmup_failed_title"], self._main_thread_queue)
                self._preview_panel.hide(self._main_thread_queue, delay=2.0)
        finally:
            self.model_ready_event.set()
            self._model_warming = False

    def load_config(self, path):
        config_path = Path(path)
        if not config_path.exists():
            log_info(f"Warning: Configuration file {path} not found. Using defaults.")
            self.load_config_data({})
            return

        try:
            data = json.loads(config_path.read_text(encoding="utf-8"))
            self.load_config_data(data)
        except Exception as e:
            log_error(f"Error loading config: {e}. Using defaults.")
            self.load_config_data({})

    def load_config_data(self, data):
        self.config = data
        if hasattr(self, "recorder"):
            self.update_recorder_settings()
        if hasattr(self, "transcriber"):
            model = self.config.get("model_name", "mlx-community/whisper-large-v3-turbo")
            if self.transcriber.model_name != model:
                self.update_transcriber(model)

    def update_config(self, updates):
        """Update config with a dict of key-value pairs, save and reload."""
        self.config.update(updates)
        self.load_config_data(self.config)
        save_config_to_disk(self.config)
        # React to ai_editor_enabled toggle from the menu
        if "ai_editor_enabled" in updates:
            if updates["ai_editor_enabled"]:
                if self.ai_editor is None or not self.ai_editor.is_ready():
                    self._init_ai_editor()
            else:
                self.ai_editor = None
                with self._ai_editor_lock:
                    self._ai_editor_loading = False
                log_info("AiEditor disabled.")

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
                self._ensure_preview_panel()
                self._preview_panel.show(s["preparing_wait_title"], self._main_thread_queue)
                self._preview_panel.hide(self._main_thread_queue, delay=2.0)
                return

            if not self.is_recording:
                # Set immediately to prevent rapid double-triggers
                self.is_recording = True 
                threading.Thread(target=self.start_recording, daemon=True).start()
            else:
                # Set immediately to lock out further triggers
                self.is_recording = False
                self.is_processing = True
                threading.Thread(target=self.stop_recording_and_process, daemon=True).start()
        except Exception as e:
            # Catch-all to avoid crashing the app from the hotkey thread
            log_exception(f"Unhandled exception in toggle_recording: {e}")

    def set_menu_bar(self, menu_bar):
        self.menu_bar = menu_bar

    def _submit_for_main_thread(self, fn, *args, **kwargs) -> None:
        """Schedule fn(*args, **kwargs) to run on the main thread (drained by menu bar timer)."""
        self._main_thread_queue.put((fn, args, kwargs))

    def notify(self, title: str, text: str = "", delay: float = 2.0) -> None:
        """Unified notification method that routes to HUD."""
        self._ensure_preview_panel()
        if self._preview_panel:
            self._preview_panel.show(title, self._main_thread_queue)
            if text:
                self._preview_panel.update_text(text, self._main_thread_queue)
            self._preview_panel.hide(self._main_thread_queue, delay=delay)

    def _do_finish_cleanup(self) -> None:
        """Run on main thread after worker has finished: clear status, save phrase, notify."""
        log_info("Finish cleanup started (main thread): clearing status, saving phrase, notifying.")
        self.is_processing = False
        with self._timer_lock:
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
        # Note: append_phrase and submenu refresh are now done in _on_confirm
        # with the user's actual final text, not the raw/AI-processed accumulation.
        s = get_ui_strings(get_primary_language(self.config))
        if self._preview_panel:
            self._preview_panel.update_status(s["ready_title"], self._main_thread_queue)
        log_info("Finish cleanup done. Ready for next recording session.")

    def _do_error_cleanup(self) -> None:
        """Run on main thread on stop_recording error: clear status, notify."""
        if self._preview_panel:
            self._preview_panel.update_status("Ошибка распознавания", self._main_thread_queue)
            self._preview_panel.hide(self._main_thread_queue, delay=2.0)
        self.is_processing = False
        mb = self.menu_bar
        if mb is not None:
            try:
                mb.set_status(recording=False, processing=False)
            except Exception as e:
                log_error(f"Failed to set menu bar status: {e}")

    def _build_confirm_cancel_callbacks(self):
        """Build on_confirm / on_cancel callbacks for the interactive edit popup.

        Extracted so the same callbacks can be reused both from process_chunk
        (normal is_final_chunk path) and from the buffered-finalization path in
        stop_recording_and_process (when Recorder.stop() returns None but partial
        chunks were already transcribed and buffered).
        """
        def _on_confirm(user_text):
            def _run_injection():
                try:
                    log_info("_run_injection: start")

                    # Log to dataset (background thread, file I/O — safe)
                    append_to_dataset(self._raw_whisper_text, self._ai_edited_text, user_text)
                    log_info("_run_injection: dataset saved")

                    if user_text:
                        append_phrase(user_text)
                        log_info("_run_injection: phrase appended")
                        mb = self.menu_bar
                        if mb is not None and hasattr(mb, "refresh_last_phrases_submenu"):
                            self._submit_for_main_thread(mb.refresh_last_phrases_submenu)

                    if not user_text:
                        log_info("_run_injection: no text to inject, skipping")
                        return

                    prev_pid = self._previous_app_pid
                    text_to_inject = user_text + " "

                    def _restore_focus():
                        if prev_pid and NSRunningApplication is not None:
                            running_app = NSRunningApplication.runningApplicationWithProcessIdentifier_(prev_pid)
                            if running_app:
                                log_info("_restore_focus: activating previous app")
                                running_app.activateWithOptions_(0)
                        # Now wait for activation, then inject on main thread.
                        def _wait_then_inject():
                            time.sleep(0.4)
                            log_info("_wait_then_inject: submitting inject_text to main thread")
                            self._submit_for_main_thread(lambda: inject_text(text_to_inject))
                        threading.Thread(target=_wait_then_inject, daemon=True).start()

                    # Small initial sleep so the panel's orderOut_ is fully
                    # processed by the main run loop before we activate another app.
                    time.sleep(0.2)
                    self._submit_for_main_thread(_restore_focus)
                    log_info("_run_injection: _restore_focus queued on main thread")

                except Exception as e:
                    log_exception(f"_run_injection failed: {e}")

            threading.Thread(target=_run_injection, daemon=True).start()

        def _on_cancel():
            log_info("User cancelled edit popup (Escape). Nothing injected.")

        return _on_confirm, _on_cancel

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
            self.recorder.silence_duration = self.config.get("silence_duration", 0.5)
            self.recorder.target_speech_duration = self.config.get("target_speech_duration", 4.0)
            self.recorder.max_speech_duration = self.config.get("max_speech_duration", 8.0)
            self.recorder.min_speech_duration = self.config.get("min_speech_duration", 0.5)
            log_info("Recorder settings updated.")

    def start_recording(self):
        if self.worker_thread is not None and self.worker_thread.is_alive():
            log_info("Previous chunk worker still running; cannot start new recording.")
            s = get_ui_strings(get_primary_language(self.config))
            if self._preview_panel:
                self._preview_panel.update_status(s["still_working_title"], self._main_thread_queue)
            return
        log_info("Starting recording...")
        # is_recording already set to True in toggle_recording() before this thread started
        self._submit_for_main_thread(
            lambda: self.menu_bar.set_status(recording=True) if self.menu_bar else None
        )
        self.transcribed_parts = []
        self._raw_whisper_text = ""
        self._raw_whisper_chunks = []
        self._ai_edited_text = None
        self.stop_worker.clear()
        self._session_id += 1  # Invalidate any lingering worker from previous session

        # Fire-and-forget prewarm: the child transcriber process will run a tiny silent
        # transcription so GPU/MLX weights are warm by the time the first real chunk arrives.
        # Recording and prewarm run in parallel; if GPU was cold this saves ~15-20s on
        # the first real chunk transcription.
        self.transcriber.pre_warm()
        log_info("Pre-warm request sent to transcriber process.")

        # Remember active app safely on main thread
        self._previous_app_pid = None
        if NSWorkspace is not None:
            def _capture_app():
                app = NSWorkspace.sharedWorkspace().frontmostApplication()
                if app:
                    self._previous_app_pid = app.processIdentifier()
            self._submit_for_main_thread(_capture_app)

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
        log_info("Starting chunk worker thread.")
        self.worker_thread.start()

        s = get_ui_strings(get_primary_language(self.config))
        self._ensure_preview_panel()
        self._preview_panel.show(s["recording_title"], self._main_thread_queue)

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
            self.notify("Ошибка", "Не удалось начать запись. Проверьте логи.")

    def on_chunk_received(self, audio_data):
        if self.is_recording:
            try:
                self.chunk_queue.put_nowait((audio_data, False))
            except queue.Full:
                log_error("chunk_queue full — dropping audio chunk (transcriber may be hung).")

    def chunk_worker(self):
        my_session_id = self._session_id
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

                # Early cancel: skip ALL non-final chunks when stop was requested.
                # The final chunk (is_final=True) is always processed; it was put into
                # the queue before stop_worker.set() so it is never skipped here.
                if self.stop_worker.is_set() and not is_final_chunk:
                    log_info("Skipping non-final chunk (stop requested).")
                    self.chunk_queue.task_done()
                    continue

                self.process_chunk(audio_chunk, is_final_chunk=is_final_chunk, session_id=my_session_id)
                self.chunk_queue.task_done()
            except queue.Empty:
                continue
            except Exception as e:
                log_exception(f"Error in chunk worker loop: {e}")
        log_info("Chunk worker stopped (queue empty, ready for next session).")

    def process_chunk(self, audio_chunk, is_final_chunk: bool = False, session_id: int = 0):
        """Transcribe a single audio chunk, accumulate result, and show popup on final chunk."""
        try:
            # Check if stop was requested before starting expensive transcription
            if self.stop_worker.is_set() and not is_final_chunk:
                log_info("Skipping non-final chunk transcription (stop requested).")
                return

            # Prepend punctuation instructions to ensure Whisper adds dots/commas
            instruction = "Расставляй знаки препинания. Пиши с заглавной буквы. "
            if self.transcribed_parts:
                full_context = " ".join(self.transcribed_parts)
                if len(full_context) > 200:
                    context = instruction + full_context[-200:]
                else:
                    context = instruction + full_context
            else:
                default_prompt = (
                    "Текст содержит русские и английские слова. "
                    "Mixed Russian and English terminology: API, bug, feature, survival."
                )
                user_prompt = str(self.config.get("initial_prompt", ""))
                context = instruction + (user_prompt or default_prompt)

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

            # Update last transcription time for keep-alive tracking
            self._last_transcription_time = time.time()

            if text:
                log_info(f"Partial Transcription (raw): {text}")
                is_ai_edited = False

                # Track raw Whisper output before any AI editing (for dataset accuracy)
                self._raw_whisper_chunks.append(text)

                if is_final_chunk:
                    # Build raw_whisper_text from pure Whisper output, not AI-edited parts
                    self._raw_whisper_text = " ".join(self._raw_whisper_chunks).strip()

                self.transcribed_parts.append(text)

                if self._session_id == session_id:
                    if is_final_chunk:
                        full_text = " ".join(self.transcribed_parts).strip()

                        # --- AI Editor post-processing (optional) ---
                        # Refine the FULL accumulated text, not just the final chunk,
                        # so partial chunks (which make up most of the content) are also
                        # punctuated and capitalized.
                        if (
                            self.ai_editor is not None
                            and self.ai_editor.is_ready()
                            and self.config.get("ai_editor_enabled", False)
                        ):
                            word_count = len(full_text.split())
                            if word_count <= 3:
                                log_info(f"AiEditor: skipping refinement for short text ({word_count} word(s)).")
                            elif self.ai_editor.is_hallucination(full_text):
                                log_info("AiEditor: skipping refinement due to hallucination filter (keeping original text).")
                            else:
                                refined = self.ai_editor.refine(full_text)
                                if refined and refined != full_text:
                                    log_info(f"AiEditor refined: {len(full_text)} → {len(refined)} chars")
                                    is_ai_edited = True
                                    self._ai_edited_text = refined
                                    full_text = refined
                        # -------------------------------------------

                        # Cancel the delayed "still working" timer under the lock.
                        def _cancel_delayed_timer():
                            with self._timer_lock:
                                if self._delayed_transcribing_timer is not None:
                                    try:
                                        self._delayed_transcribing_timer.cancel()
                                    except Exception:
                                        pass
                                    self._delayed_transcribing_timer = None
                        self._submit_for_main_thread(_cancel_delayed_timer)

                        _on_confirm, _on_cancel = self._build_confirm_cancel_callbacks()

                        s_ui = get_ui_strings(get_primary_language(self.config))
                        log_info(
                            f"process_chunk: ready to show interactive popup. "
                            f"full_text_len={len(full_text)}, "
                            f"preview_panel={self._preview_panel is not None}, "
                            f"session_id={session_id}"
                        )
                        if full_text and self._preview_panel:
                            self._preview_panel.show_interactive(
                                full_text,
                                self._main_thread_queue,
                                on_confirm=_on_confirm,
                                on_cancel=_on_cancel,
                                title=s_ui["edit_confirm_title"],
                            )
                            log_info("process_chunk: show_interactive queued on main thread")
                        elif self._preview_panel:
                            self._preview_panel.hide(self._main_thread_queue, delay=0.8)
                    else:
                        accumulated = " ".join(self.transcribed_parts).strip()
                        if self._preview_panel:
                            self._preview_panel.update_text(accumulated, self._main_thread_queue)
                        log_info(
                            f"Partial chunk buffered ({len(self.transcribed_parts)} chunk(s))"
                        )
                else:
                    if self._preview_panel:
                        self._preview_panel.hide(self._main_thread_queue, delay=0.0)
                    log_info(
                        f"Chunk dropped: session invalidated "
                        f"(worker={session_id}, current={self._session_id}), text='{text[:60]}'"
                    )
            else:
                log_info("Transcriber returned empty text for this chunk.")
                if is_final_chunk and not self.transcribed_parts and self._session_id == session_id:
                    self.notify("Нет речи", "Не удалось распознать речь. Попробуйте ещё раз.", delay=2.0)
                if is_final_chunk and self.transcribed_parts and self._session_id == session_id:
                    full_text = " ".join(self.transcribed_parts).strip()
                    if full_text and self._preview_panel:
                        self._raw_whisper_text = " ".join(self._raw_whisper_chunks).strip()
                        _on_confirm, _on_cancel = self._build_confirm_cancel_callbacks()
                        s_ui = get_ui_strings(get_primary_language(self.config))
                        log_info(
                            f"process_chunk: final chunk empty but {len(self.transcribed_parts)} "
                            f"buffered partial(s) available, showing popup. full_text_len={len(full_text)}"
                        )
                        self._preview_panel.show_interactive(
                            full_text,
                            self._main_thread_queue,
                            on_confirm=_on_confirm,
                            on_cancel=_on_cancel,
                            title=s_ui["edit_confirm_title"],
                        )
                        log_info("process_chunk: show_interactive queued (final chunk empty, using buffered partials)")
        except Exception as e:
            log_exception(f"Unhandled exception in process_chunk: {e}")

    def stop_recording_and_process(self):
        log_info("Stopping recording and finalizing transcription...")
        my_session_id = self._session_id
        try:
            self.is_recording = False
            self.is_processing = True
            self._submit_for_main_thread(
                lambda: self.menu_bar.set_status(recording=False, processing=True)
                if self.menu_bar
                else None
            )

            s = get_ui_strings(get_primary_language(self.config))
            if self._preview_panel:
                self._preview_panel.update_status(s["transcribing_title"], self._main_thread_queue)

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
                try:
                    self.chunk_queue.put_nowait((last_audio, True))
                    log_info(
                        "Final audio chunk added to queue (worker will process it in order)."
                    )
                except Exception:
                    log_error("Chunk queue full — final audio chunk dropped.")

            # Signal worker to finish and wait for it (long timeout so "Finish" only after real completion)
            self.stop_worker.set()
            wait_start = time.time()

            # Schedule a delayed "still working" notification if recognition is slow.
            # Use _timer_lock so creation here (background thread) doesn't race with
            # cancellation in _do_finish_cleanup or _cancel_delayed_timer (main thread).
            self._transcription_cycle_id += 1
            cycle_id = self._transcription_cycle_id

            def _delayed_notify() -> None:
                try:
                    if self._transcription_cycle_id != cycle_id:
                        return
                    if self.worker_thread is not None and self.worker_thread.is_alive():
                        s = get_ui_strings(get_primary_language(self.config))
                        if self._preview_panel:
                            self._preview_panel.update_status(s["still_working_title"], self._main_thread_queue)
                except Exception as e:
                    log_exception(f"Delayed transcription notify failed: {e}")

            with self._timer_lock:
                if self._delayed_transcribing_timer is not None:
                    try:
                        self._delayed_transcribing_timer.cancel()
                    except Exception:
                        pass
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
                waited = time.time() - wait_start
                if self.worker_thread.is_alive():
                    log_error(
                        f"Worker thread did not finish within timeout. "
                        f"Waited {waited:.1f}s. Force-resetting is_processing."
                    )
                    # Force-reset so hotkeys are not permanently blocked.
                    # We do NOT invalidate the session here: the worker is still
                    # running and will show the popup once transcription finishes.
                    # The session is only invalidated when the user starts a new
                    # recording (via start_recording → _session_id += 1).
                    self.is_processing = False
                else:
                    log_info(
                        f"Worker thread finished. Waited {waited:.1f}s. "
                        "Submitting finish cleanup to main thread."
                    )

            # If Recorder.stop() returned no final audio chunk (e.g. the last
            # chunk was too short and discarded) but the worker already buffered
            # one or more partial transcriptions, finalise them now so the text
            # is not silently lost.
            if (
                last_audio is None
                and self.transcribed_parts
                and self._session_id == my_session_id
                and self._preview_panel is not None
                and not (self.worker_thread is not None and self.worker_thread.is_alive())
            ):
                self._raw_whisper_text = " ".join(self._raw_whisper_chunks).strip()
                full_text = " ".join(self.transcribed_parts).strip()
                if full_text:
                    log_info(
                        f"No final audio chunk; finalizing {len(self.transcribed_parts)} "
                        f"buffered partial chunk(s). full_text_len={len(full_text)}"
                    )
                    _on_confirm, _on_cancel = self._build_confirm_cancel_callbacks()
                    s_ui = get_ui_strings(get_primary_language(self.config))
                    self._preview_panel.show_interactive(
                        full_text,
                        self._main_thread_queue,
                        on_confirm=_on_confirm,
                        on_cancel=_on_cancel,
                        title=s_ui["edit_confirm_title"],
                    )
                    log_info("Buffered finalization: show_interactive queued on main thread")

            # All UI updates and "Finish" run on main thread so menu bar actually updates
            self._submit_for_main_thread(self._do_finish_cleanup)
            log_info("Stop-recording phase done (cleanup scheduled on main thread).")
        except Exception as e:
            log_exception(f"Unhandled exception in stop_recording_and_process: {e}")
            self._submit_for_main_thread(self._do_error_cleanup)

    def start_file_transcription(self, file_path: str):
        if self.is_recording or self.is_processing:
            log_info(f"Ignoring file transcription request; already busy. is_recording={self.is_recording}, is_processing={self.is_processing}")
            return
            
        self.is_processing = True
        self._submit_for_main_thread(
            lambda: self.menu_bar.set_status(recording=False, processing=True) if self.menu_bar else None
        )
        
        self.notify("Распознавание файла", f"Обработка {Path(file_path).name}...")
        
        threading.Thread(target=self._file_transcription_worker, args=(file_path,), daemon=True).start()

    def _file_transcription_worker(self, file_path: str):
        log_info(f"File transcription worker started for {file_path}")
        # Initialise before try so the except block can always reference it safely.
        _file_notify_timer: Optional[threading.Timer] = None
        # Cycle ID prevents stale timer callback from firing after cancellation race.
        self._file_cycle_id = getattr(self, "_file_cycle_id", 0) + 1
        _cycle_id = self._file_cycle_id
        try:
            allowed_languages = get_allowed_languages(self.config)
            context = str(self.config.get("initial_prompt", ""))

            # Notify the user if the file is taking longer than 12 seconds.
            def _file_still_working():
                if self._file_cycle_id != _cycle_id:
                    return
                if self.is_processing and self._preview_panel:
                    s = get_ui_strings(get_primary_language(self.config))
                    self._preview_panel.update_status(s["still_working_title"], self._main_thread_queue)

            _file_notify_timer = threading.Timer(self._still_working_delay_seconds, _file_still_working)
            _file_notify_timer.daemon = True
            _file_notify_timer.start()

            self._last_transcription_time = time.time()

            text = self.transcriber.transcribe_file(
                file_path,
                initial_prompt=context,
                allowed_languages=allowed_languages,
            )
            _file_notify_timer.cancel()

            self._last_transcription_time = time.time()

            if text:
                log_info(f"File transcription successful, {len(text)} chars.")

                from pathlib import Path
                src = Path(file_path)
                output_file = Path.home() / "Downloads" / f"{src.stem}_transcription.md"

                try:
                    output_file.write_text(
                        f"# Transcription: {src.name}\n\n{text}", encoding="utf-8"
                    )
                    log_info(f"Saved transcription to {output_file}")

                    self.transcribed_parts = [f"File saved to {output_file}"]

                    from .utils import copy_to_clipboard
                    copy_to_clipboard(text)

                    self.notify("Файл распознан", f"Сохранено: {output_file.name} (и скопировано!)", delay=3.0)
                except Exception as write_err:
                    log_error(f"Failed to write markdown file: {write_err}")
                    self.notify("Ошибка", "Не удалось сохранить файл.")
            else:
                log_info("File transcription returned empty text.")
                self.notify("Нет речи", "Не удалось извлечь текст из файла.")

        except Exception as e:
            if _file_notify_timer is not None:
                _file_notify_timer.cancel()
            log_exception(f"Unhandled exception in _file_transcription_worker: {e}")
            self._submit_for_main_thread(self._do_error_cleanup)
            return

        self._submit_for_main_thread(self._do_finish_cleanup)

    def stop(self):
        self.stop_worker.set()

        # Stop the audio stream first — otherwise the recorder callback keeps
        # firing and can re-enqueue work while we're trying to drain the worker.
        if hasattr(self, "recorder") and self.recorder.recording:
            try:
                self.recorder.stop()
            except Exception as e:
                log_error(f"Recorder stop error: {e}")

        # Stop the transcriber child process before joining the worker thread so
        # the worker's blocking transcribe() call unblocks immediately instead of
        # waiting up to TRANSCRIBER_TIMEOUT_SECONDS (30s) for a response.
        if hasattr(self, "transcriber"):
            self.transcriber.stop()

        if self.worker_thread is not None and self.worker_thread.is_alive():
            self.worker_thread.join(timeout=5.0)

        if self.hotkey_handler:
            self.hotkey_handler.stop()

        self._stop_keep_alive_timer()

    # ── Keep-alive & Wake-from-sleep ───────────────────────────────────────

    def start_keep_alive_timer(self) -> None:
        """Start the periodic keep-alive timer to prevent MLX cold-start delays."""
        self._schedule_keep_alive()
        log_info(f"Keep-alive timer started (interval={KEEP_ALIVE_INTERVAL_SECONDS}s).")

    def _schedule_keep_alive(self) -> None:
        """Schedule the next keep-alive check."""
        self._keep_alive_timer = threading.Timer(
            KEEP_ALIVE_INTERVAL_SECONDS, self._keep_alive_tick
        )
        self._keep_alive_timer.daemon = True
        self._keep_alive_timer.start()

    def _keep_alive_tick(self) -> None:
        """Periodic check: if no transcription happened recently, do a warmup ping."""
        try:
            elapsed = time.time() - self._last_transcription_time
            if elapsed < KEEP_ALIVE_INTERVAL_SECONDS:
                log_info(
                    f"Keep-alive: last transcription {elapsed:.0f}s ago, "
                    "model still warm — skipping ping."
                )
                return

            # Check memory pressure before pinging
            if self._is_memory_pressure_high():
                log_info(
                    "Keep-alive: memory pressure high, skipping warmup ping "
                    "to avoid adding load."
                )
                return

            log_info(
                f"Keep-alive: no transcription for {elapsed:.0f}s, "
                "sending warmup ping to keep model warm."
            )
            # Warmup in a separate thread to not block the timer
            threading.Thread(
                target=self._do_keep_alive_warmup, daemon=True
            ).start()
        except Exception as e:
            log_exception(f"Keep-alive tick error: {e}")
        finally:
            self._schedule_keep_alive()

    def _do_keep_alive_warmup(self) -> None:
        """Perform a real silent transcription to keep GPU/MLX weights in active memory.

        Uses pre_warm() instead of warmup() for two reasons:
        1. warmup() is a no-op after first call (_warmup_done guard in WhisperTranscriber).
        2. The old approach drained output_queue directly, which could race with a
           concurrent transcribe() call and steal its result, causing a 30s timeout.
        pre_warm() fire-and-forgets; the prewarm_done response is silently consumed
        by the next transcribe() call (which ignores non-"transcription" messages).
        """
        if not self._keep_alive_lock.acquire(blocking=False):
            log_info("Keep-alive: previous warmup still running — skipping.")
            return
        try:
            self.transcriber.pre_warm()
            log_info("Keep-alive: pre_warm() sent to transcriber process.")
            self._last_transcription_time = time.time()
        except Exception as e:
            log_error(f"Keep-alive warmup failed: {e}")
        finally:
            self._keep_alive_lock.release()

    def _stop_keep_alive_timer(self) -> None:
        """Cancel the keep-alive timer."""
        if self._keep_alive_timer is not None:
            try:
                self._keep_alive_timer.cancel()
            except Exception:
                pass
            self._keep_alive_timer = None

    def _is_memory_pressure_high(self) -> bool:
        """Check if system memory usage exceeds the threshold."""
        try:
            import psutil
            mem = psutil.virtual_memory()
            return mem.percent > MEMORY_PRESSURE_THRESHOLD_PERCENT
        except ImportError:
            # psutil not available — assume memory is fine
            return False
        except Exception as e:
            log_error(f"Error checking memory pressure: {e}")
            return False

    def start_wake_observer(self) -> None:
        """Subscribe to macOS NSWorkspaceDidWakeNotification to warmup model after sleep."""
        try:
            from AppKit import NSWorkspace, NSWorkspaceDidWakeNotification, NSObject
            import objc

            app_ref = self  # Capture reference for the observer callback

            class _WakeObserver(NSObject):
                def onWake_(self, notification):
                    log_info("System wake detected — scheduling model warmup in background.")
                    threading.Thread(
                        target=app_ref._do_keep_alive_warmup, daemon=True
                    ).start()

            self._wake_observer = _WakeObserver.alloc().init()
            workspace = NSWorkspace.sharedWorkspace()
            workspace.notificationCenter().addObserver_selector_name_object_(
                self._wake_observer, 'onWake:', NSWorkspaceDidWakeNotification, None
            )
            log_info("Wake-from-sleep observer registered successfully.")
        except ImportError:
            log_info("AppKit not available — wake-from-sleep warmup disabled.")
        except Exception as e:
            log_error(f"Failed to register wake observer: {e}")
