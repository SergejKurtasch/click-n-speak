import json
import queue
import threading
import time
from pathlib import Path
from typing import Callable, Optional

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
from .ai_editor import AiEditor, DEFAULT_MODEL_NAME, GeminiEditor, DEFAULT_GEMINI_MODEL
from .transcriber import TranscriberProcessWrapper, TRANSCRIBER_COLD_START_TIMEOUT_SECONDS, FileTranscriptionError
from .utils import (
    build_initial_prompt,
    deduplicate_prompt_terms,
    get_allowed_languages,
    get_primary_language,
    get_ui_strings,
    log_error,
    log_exception,
    log_info,
    migrate_config_to_v2,
    migrate_config_to_v3,
    migrate_config_to_v4,
    save_config_to_disk,
    send_notification,
)

# Keep-alive interval in seconds (15 minutes)
KEEP_ALIVE_INTERVAL_SECONDS = 15 * 60


def _join_chunks(parts: list[str]) -> str:
    """Join Whisper chunk texts, removing spurious sentence-ending punctuation at
    chunk boundaries where the next chunk continues mid-sentence (starts with a
    lowercase letter).  Whisper independently punctuates each chunk, so a period
    appended to a non-final chunk frequently lands in the middle of a sentence."""
    if len(parts) <= 1:
        return " ".join(parts).strip()
    result = parts[0]
    for part in parts[1:]:
        if result and part and result[-1] in ".!?" and part[0].islower():
            result = result[:-1]
        result += " " + part
    return result.strip()

# Restart the transcriber child process every N completed sessions.
# MLX weight tensors are never freed by clear_cache() (they're always referenced);
# only a full process restart resets them. 20 sessions ≈ 15-30 min of typical use.
TRANSCRIBER_RESTART_AFTER_SESSIONS = 20


def _apply_candidates_to_user_terms(config: dict, candidates: dict) -> None:
    """Merge candidates into user_terms[lang], dedup.

    Existing user-curated terms come first; new auto-detected terms are appended.
    build_initial_prompt enforces the final length via _MAX_PROMPT_CHARS.
    """
    user_terms = dict(config.get("user_terms") or {})
    for lang, items in candidates.items():
        new_terms = [item["term"] for item in items]
        current = list(user_terms.get(lang, []))
        user_terms[lang] = deduplicate_prompt_terms(current + new_terms)
    config["user_terms"] = user_terms
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
        # AI Editor: optional LLM post-processing for punctuation and cleanup.
        # Backend is chosen by config["ai_editor_backend"]: "local" (MLX) or "gemini".
        self.ai_editor: Optional[AiEditor] = None
        self.gemini_editor: Optional[GeminiEditor] = None
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
        self._completed_sessions: int = 0  # incremented on each finished recording session
        self._analysis_lock = threading.Lock()  # prevents concurrent prompt-analysis threads
        self._wake_observer = None  # macOS wake observer (set in start_wake_observer)
        self._preview_panel = None  # lazy-init on first use
        self._previous_app_pid = None
        self._append_to_popup: bool = False  # True when hotkey fired while popup was open
        self._raw_whisper_text = ""
        self._raw_whisper_chunks = []  # raw Whisper output per chunk, before AI editing
        self._ai_edited_text = None
        self._ai_editor_status: Optional[str] = None

        # Cached result of build_initial_prompt(). Invalidated by load_config_data()
        # so process_chunk() avoids rebuilding (dedup+join+truncate) on every chunk.
        self._cached_initial_prompt: str = ""
        self._initial_prompt_dirty: bool = True

    def _ensure_preview_panel(self):
        if self._preview_panel is None:
            from .preview_panel import TranscriptionPreviewPanel
            self._preview_panel = TranscriptionPreviewPanel()

    def _init_ai_editor(self) -> None:
        """Create and load the AI editor backend in a background thread (non-blocking).

        Backend is selected by config["ai_editor_backend"]:
          "gemini"  — GeminiEditor (API call, requires GOOGLE_API_KEY)
          "local"   — AiEditor (MLX local model, default)
        """
        with self._ai_editor_lock:
            if self._ai_editor_loading:
                return
            self._ai_editor_loading = True

        backend = self.config.get("ai_editor_backend", "local")
        if backend == "gemini":
            self.ai_editor = None  # release stale local model from GPU RAM
            model_name = self.config.get("gemini_model", DEFAULT_GEMINI_MODEL)
            self.gemini_editor = GeminiEditor(model_name=model_name)
            threading.Thread(target=self._gemini_editor_load_worker, daemon=True).start()
        else:
            self.gemini_editor = None  # release stale Gemini client
            model_name = self.config.get("ai_editor_model", DEFAULT_MODEL_NAME)
            self.ai_editor = AiEditor(model_name=model_name)
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

    def _gemini_editor_load_worker(self) -> None:
        """Background worker: initialise the Gemini API client."""
        try:
            editor = self.gemini_editor
            if editor is None:
                return
            editor.load()
            if editor.is_ready():
                self.notify("AI Editor Готов", f"Gemini ({editor.model_name}) активирован.")
                log_info(f"GeminiEditor loaded and ready (model={editor.model_name}).")
            else:
                log_error("GeminiEditor failed to initialise — editor will be skipped.")
                self.notify("AI Editor: Ошибка", "Не удалось подключиться к Gemini API. Проверьте GOOGLE_API_KEY.")
        except Exception as e:
            log_exception(f"GeminiEditor background load failed: {e}")
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
        data = migrate_config_to_v2(data)
        data = migrate_config_to_v3(data)
        data = migrate_config_to_v4(data)
        self.config = data
        # Invalidate the cached prompt so process_chunk() rebuilds it on the next chunk.
        if hasattr(self, "_initial_prompt_dirty"):
            self._initial_prompt_dirty = True
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
                backend = self.config.get("ai_editor_backend", "local")
                if backend == "gemini":
                    active = self.gemini_editor
                else:
                    active = self.ai_editor
                if active is None or not active.is_ready():
                    self._init_ai_editor()
            else:
                self.ai_editor = None
                self.gemini_editor = None
                with self._ai_editor_lock:
                    self._ai_editor_loading = False
                log_info("AiEditor disabled.")
        # React to backend switch — load the newly selected editor if not already ready
        if "ai_editor_backend" in updates and self.config.get("ai_editor_enabled", False):
            self._init_ai_editor()

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
                self._append_to_popup = (
                    self._preview_panel is not None
                    and self._preview_panel._is_interactive
                )
                if self._append_to_popup:
                    log_info("Popup is open — new recording will append to existing text.")
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
        self._completed_sessions += 1
        if self._completed_sessions % TRANSCRIBER_RESTART_AFTER_SESSIONS == 0:
            threading.Thread(target=self._restart_transcriber_for_memory, daemon=True).start()

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
                    append_to_dataset(
                        self._raw_whisper_text,
                        self._ai_edited_text,
                        user_text,
                        ai_status=self._ai_editor_status,
                    )
                    log_info("_run_injection: dataset saved")

                    if user_text:
                        append_phrase(user_text)
                        log_info("_run_injection: phrase appended")
                        self._maybe_trigger_prompt_analysis()
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

    # ------------------------------------------------------------------
    # Automatic prompt analysis
    # ------------------------------------------------------------------

    def _maybe_trigger_prompt_analysis(self) -> None:
        """Start background analysis if enough new phrases have accumulated."""
        mode = self.config.get("prompt_update_mode", "suggest")
        if mode == "disabled":
            return
        interval = int(self.config.get("auto_prompt_check_interval", 50))
        last_check = int(self.config.get("last_analysis_phrase_count", 0))
        try:
            from .phrase_history import count_phrases
            current = count_phrases()
        except Exception:
            return
        if current - last_check < interval:
            return
        if not self._analysis_lock.acquire(blocking=False):
            return  # previous analysis still running
        # Pass the already-read count so _run_prompt_analysis skips a second file scan.
        threading.Thread(
            target=self._run_prompt_analysis,
            kwargs={"current_phrase_count": current},
            daemon=True,
        ).start()

    def request_prompt_analysis(self, on_complete: Callable[[], None] | None = None) -> None:
        """Start an on-demand analysis immediately, bypassing the interval check.

        Uses softer thresholds (lookback=500, min_count=5) so the user sees
        results even from sparse history. Does not update last_analysis_phrase_count
        so the regular auto-analysis schedule is unaffected.
        on_complete, if given, is posted to the main-thread queue after analysis.
        """
        if not self._analysis_lock.acquire(blocking=False):
            log_info("Prompt analysis already running, skipping on-demand request.")
            if on_complete is not None:
                self._submit_for_main_thread(on_complete)
            return
        threading.Thread(
            target=self._run_prompt_analysis,
            kwargs={"on_demand": True, "on_complete": on_complete},
            daemon=True,
        ).start()

    def _run_prompt_analysis(
        self,
        on_demand: bool = False,
        on_complete: Callable[[], None] | None = None,
        current_phrase_count: int | None = None,
    ) -> None:
        """Background thread: analyse phrase history, update user_terms or pending_suggestions.

        on_demand=True uses softer parameters and skips the interval counter update.
        on_complete is called on the main thread after analysis finishes (success or empty).
        current_phrase_count, if provided, avoids a redundant file scan (already done by caller).
        """
        try:
            from .log_analyzer import get_prompt_candidates
            from .phrase_history import count_phrases

            current_count = current_phrase_count if current_phrase_count is not None else count_phrases()

            existing: dict[str, set[str]] = {}
            for lang, terms in (self.config.get("user_terms") or {}).items():
                existing.setdefault(lang, set()).update(t.lower() for t in terms)

            skipped_raw = self.config.get("skipped_terms") or {}
            skipped: dict[str, dict[str, int]] = {
                lang: {t.lower(): cnt for t, cnt in terms.items()}
                for lang, terms in skipped_raw.items()
            }

            if on_demand:
                lookback = 500
                min_count = 10
            else:
                lookback = 100
                min_count = int(self.config.get("auto_prompt_check_min_count", 10))

            candidates = get_prompt_candidates(
                lookback=lookback,
                min_count=min_count,
                existing_lower_by_lang=existing,
                skipped_lower_by_lang=skipped,
                current_phrase_count=current_count,
                cooldown_phrases=100,
            )

            # Remap candidate buckets that don't match any active language to primary.
            # get_prompt_candidates uses script-based detection ("en" for Latin, "ru" for
            # Cyrillic), which may not align with the user's configured languages.
            primary_lang = get_primary_language(self.config)
            active_langs = {primary_lang} | set(self.config.get("additional_languages") or [])
            remapped: dict[str, list[dict]] = {}
            for lang, items in candidates.items():
                target = lang if lang in active_langs else primary_lang
                existing_items = remapped.get(target, [])
                seen_lower = {item["term"].lower() for item in existing_items}
                for item in items:
                    if item["term"].lower() not in seen_lower:
                        existing_items.append(item)
                        seen_lower.add(item["term"].lower())
                remapped[target] = sorted(existing_items, key=lambda x: -x["count"])
            candidates = remapped

            if not on_demand:
                self.config["last_analysis_phrase_count"] = current_count
            mode = self.config.get("prompt_update_mode", "suggest")

            if mode == "auto" and candidates:
                _apply_candidates_to_user_terms(self.config, candidates)
                self.config["initial_prompt"] = build_initial_prompt(self.config)
                save_config_to_disk(self.config)
                # load_config_data and prompt-file sync must run on the main thread.
                self._submit_for_main_thread(self.load_config_data, self.config)
                mb = self.menu_bar
                if mb is not None and hasattr(mb, "_sync_prompt_file"):
                    for lang in candidates:
                        self._submit_for_main_thread(mb._sync_prompt_file, lang)
                total = sum(len(v) for v in candidates.values())
                log_info(f"Auto-applied {total} prompt candidates to user_terms.")
            elif mode == "suggest" and candidates:
                # Merge with existing pending: update count for known terms, add new ones.
                existing_pending = dict(self.config.get("pending_suggestions") or {})
                merged: dict[str, list[dict]] = {}
                for lang in set(existing_pending) | set(candidates):
                    by_lower: dict[str, dict] = {}
                    for item in existing_pending.get(lang, []):
                        by_lower[item["term"].lower()] = dict(item)
                    for item in candidates.get(lang, []):
                        lower = item["term"].lower()
                        if lower in by_lower:
                            by_lower[lower]["count"] = max(by_lower[lower]["count"], item["count"])
                        else:
                            by_lower[lower] = dict(item)
                    merged[lang] = sorted(by_lower.values(), key=lambda x: -x["count"])
                self.config["pending_suggestions"] = merged
                save_config_to_disk(self.config)
                mb = self.menu_bar
                if mb is not None and hasattr(mb, "update_suggest_menu_badge"):
                    self._submit_for_main_thread(mb.update_suggest_menu_badge)
            else:
                save_config_to_disk(self.config)

            if on_complete is not None:
                self._submit_for_main_thread(on_complete)

        except Exception as exc:
            log_exception(f"Prompt analysis failed: {exc}")
            if on_complete is not None:
                self._submit_for_main_thread(on_complete)
        finally:
            self._analysis_lock.release()

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
        self._ai_editor_status = None
        self.stop_worker.clear()
        self._session_id += 1  # Invalidate any lingering worker from previous session

        # Fire-and-forget prewarm: the child transcriber process will run a tiny silent
        # transcription so GPU/MLX weights are warm by the time the first real chunk arrives.
        # Recording and prewarm run in parallel; if GPU was cold this saves ~15-20s on
        # the first real chunk transcription.
        self.transcriber.pre_warm()
        log_info("Pre-warm request sent to transcriber process.")

        # Remember active app safely on main thread.
        # In append mode the popup is already open and _previous_app_pid is still correct
        # (the user's app, not ours), so we must not overwrite it.
        if not self._append_to_popup:
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
        if not self._append_to_popup:
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

                self.process_chunk(audio_chunk, is_final_chunk=is_final_chunk, session_id=my_session_id)
                self.chunk_queue.task_done()
            except queue.Empty:
                continue
            except Exception as e:
                log_exception(f"Error in chunk worker loop: {e}")
        log_info("Chunk worker stopped (queue empty, ready for next session).")
        # Primary cleanup path for normal and timeout flows.
        # Buffered-finalization path submits cleanup inline in stop_recording_and_process
        # (after show_interactive) so is_processing stays True until the popup appears.
        # For normal and timeout flows this is the only cleanup submission.
        if self._session_id == my_session_id:
            self._submit_for_main_thread(self._do_finish_cleanup)

    def process_chunk(self, audio_chunk, is_final_chunk: bool = False, session_id: int = 0):
        """Transcribe a single audio chunk, accumulate result, and show popup on final chunk."""
        try:
            # Build context: always keep the full vocab prompt, then fill the
            # remaining token budget with whole recent chunks (newest first) so
            # vocabulary terms stay in context for every chunk, not just the first.
            s = get_ui_strings(get_primary_language(self.config))
            instruction = s["transcription_instruction"]
            # Use cached prompt — rebuild only when config changed (load_config_data sets dirty flag).
            if self._initial_prompt_dirty:
                self._cached_initial_prompt = build_initial_prompt(self.config)
                self._initial_prompt_dirty = False
            vocab_prompt = self._cached_initial_prompt
            if self.transcribed_parts:
                # Whisper's prompt window is ~224 tokens (~700 chars for mixed text).
                # Subtract fixed parts to get chars available for recent speech context.
                _WHISPER_PROMPT_BUDGET = 700
                available = max(0, _WHISPER_PROMPT_BUDGET - len(instruction) - len(vocab_prompt) - 1)
                recent: list[str] = []
                used = 0
                for chunk in reversed(self.transcribed_parts):
                    needed = len(chunk) + (1 if recent else 0)
                    if used + needed > available:
                        break
                    recent.append(chunk)
                    used += needed
                recent.reverse()
                recent_text = " ".join(recent)
                context = instruction + vocab_prompt + (" " + recent_text if recent_text else "")
            else:
                context = instruction + vocab_prompt

            allowed_languages = get_allowed_languages(self.config)
            condition_on_previous_text = self.config.get(
                "condition_on_previous_text", True
            )

            # Detect cold start: first chunk of this session after long idle or under memory
            # pressure — GPU weights may be paged out and need extra time to reload.
            # Use an extended timeout so the process is not killed prematurely.
            _COLD_START_IDLE_THRESHOLD = 5 * 60  # 5 minutes
            last_returned = getattr(self.transcriber, "_last_transcribe_returned_at", 0.0)
            idle_since_last = time.time() - (last_returned if isinstance(last_returned, (int, float)) else 0.0)
            is_cold_start = len(self.transcribed_parts) == 0 and (
                idle_since_last > _COLD_START_IDLE_THRESHOLD
                or self._is_memory_pressure_high()
            )
            timeout_override = TRANSCRIBER_COLD_START_TIMEOUT_SECONDS if is_cold_start else None

            log_info(
                "Processing audio chunk: "
                f"len={len(audio_chunk)}, "
                f"allowed_languages={allowed_languages}, "
                f"condition_on_previous_text={condition_on_previous_text}, "
                f"context_len={len(context)}"
                + (", is_final_chunk=True" if is_final_chunk else "")
                + (f", cold_start_timeout={timeout_override:.0f}s (idle {idle_since_last:.0f}s)" if is_cold_start else "")
            )

            text = self.transcriber.transcribe(
                audio_chunk,
                initial_prompt=context,
                allowed_languages=allowed_languages,
                condition_on_previous_text=condition_on_previous_text,
                is_final_chunk=is_final_chunk,
                timeout_override=timeout_override,
            )

            # Update last transcription time for keep-alive tracking
            self._last_transcription_time = time.time()

            if text:
                log_info(f"Partial Transcription (raw): {text}")
                is_ai_edited = False

                # Session guard: check BEFORE mutating shared state so a stale worker
                # from a previous session never pollutes transcribed_parts of the new one.
                if self._session_id != session_id:
                    if self._preview_panel:
                        self._preview_panel.hide(self._main_thread_queue, delay=0.0)
                    log_info(
                        f"Chunk dropped: session invalidated "
                        f"(worker={session_id}, current={self._session_id}), text='{text[:60]}'"
                    )
                    return

                # Track raw Whisper output before any AI editing (for dataset accuracy)
                self._raw_whisper_chunks.append(text)

                if is_final_chunk:
                    # Build raw_whisper_text from pure Whisper output, not AI-edited parts
                    self._raw_whisper_text = " ".join(self._raw_whisper_chunks).strip()

                self.transcribed_parts.append(text)

                if is_final_chunk:
                    full_text = _join_chunks(self.transcribed_parts)

                    # --- AI Editor post-processing (optional) ---
                    # Refine the FULL accumulated text, not just the final chunk,
                    # so partial chunks (which make up most of the content) are also
                    # punctuated and capitalized.
                    _active_editor = (
                        self.gemini_editor if (
                            self.config.get("ai_editor_backend", "local") == "gemini"
                            and self.gemini_editor is not None
                            and self.gemini_editor.is_ready()
                        ) else (
                            self.ai_editor if (
                                self.ai_editor is not None
                                and self.ai_editor.is_ready()
                            ) else None
                        )
                    )
                    if _active_editor is not None and self.config.get("ai_editor_enabled", False):
                        is_gemini = isinstance(_active_editor, GeminiEditor)
                        if not is_gemini and self._is_memory_pressure_high():
                            # Under memory pressure Qwen's GPU thread blocks and can't be
                            # interrupted cleanly, causing 8.5s + 2s stuck-thread delays.
                            # Skip refinement entirely and notify the user.
                            log_info("AiEditor: skipping refinement — memory pressure high.")
                            self._ai_editor_status = AiEditor.REFINE_STATUS_MEMORY_PRESSURE
                            self._ai_edited_text = full_text
                            self._submit_for_main_thread(self._send_memory_pressure_notification)
                        else:
                            word_count = len(full_text.split())
                            if word_count <= 3:
                                log_info(f"AiEditor: skipping refinement for short text ({word_count} word(s)).")
                            elif not is_gemini and self.ai_editor.is_hallucination(full_text):
                                log_info("AiEditor: skipping refinement due to hallucination filter (keeping original text).")
                            else:
                                refined = _active_editor.refine(full_text, languages=get_allowed_languages(self.config))
                                # Always capture what the AI produced and its status so the
                                # dataset record distinguishes "AI ran but unchanged" from
                                # "AI was disabled / skipped / timed out".
                                self._ai_edited_text = refined
                                self._ai_editor_status = _active_editor.last_refine_status
                                if refined and refined != full_text:
                                    is_ai_edited = True
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
                        if self._append_to_popup and self._preview_panel._is_interactive:
                            self._preview_panel.append_text(full_text, self._main_thread_queue)
                            self._append_to_popup = False
                            log_info(f"process_chunk: appended to existing popup, len={len(full_text)}")
                        else:
                            self._append_to_popup = False
                            self._preview_panel.show_interactive(
                                full_text,
                                self._main_thread_queue,
                                on_confirm=_on_confirm,
                                on_cancel=_on_cancel,
                                title=s_ui["edit_confirm_title"],
                            )
                            log_info("process_chunk: show_interactive queued on main thread")
                    elif self._preview_panel:
                        self._append_to_popup = False
                        self._preview_panel.hide(self._main_thread_queue, delay=0.8)
                else:
                    accumulated = _join_chunks(self.transcribed_parts)
                    if self._preview_panel:
                        self._preview_panel.update_text(accumulated, self._main_thread_queue)
                    log_info(
                        f"Partial chunk buffered ({len(self.transcribed_parts)} chunk(s))"
                    )
            else:
                log_info("Transcriber returned empty text for this chunk.")
                if is_final_chunk and not self.transcribed_parts and self._session_id == session_id:
                    self.notify("Нет речи", "Не удалось распознать речь. Попробуйте ещё раз.", delay=2.0)
                if is_final_chunk and self.transcribed_parts and self._session_id == session_id:
                    full_text = _join_chunks(self.transcribed_parts)
                    if full_text and self._preview_panel:
                        self._raw_whisper_text = " ".join(self._raw_whisper_chunks).strip()
                        s_ui = get_ui_strings(get_primary_language(self.config))
                        if self._append_to_popup and self._preview_panel._is_interactive:
                            self._preview_panel.append_text(full_text, self._main_thread_queue)
                            self._append_to_popup = False
                            log_info(
                                f"process_chunk: appended buffered partials to popup, len={len(full_text)}"
                            )
                        else:
                            _on_confirm, _on_cancel = self._build_confirm_cancel_callbacks()
                            self._append_to_popup = False
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

            worker_timed_out = False
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
                    worker_timed_out = True
                    # Keep showing "still working" — chunk_worker will submit
                    # _do_finish_cleanup when it actually completes.
                    if self._preview_panel:
                        s_wt = get_ui_strings(get_primary_language(self.config))
                        self._preview_panel.update_status(
                            s_wt["still_working_title"], self._main_thread_queue
                        )
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
                full_text = _join_chunks(self.transcribed_parts)
                if full_text:
                    s_ui = get_ui_strings(get_primary_language(self.config))
                    if self._append_to_popup and self._preview_panel._is_interactive:
                        self._preview_panel.append_text(full_text, self._main_thread_queue)
                        self._append_to_popup = False
                        log_info(
                            f"Buffered finalization: appended to existing popup, len={len(full_text)}"
                        )
                    else:
                        log_info(
                            f"No final audio chunk; finalizing {len(self.transcribed_parts)} "
                            f"buffered partial chunk(s). full_text_len={len(full_text)}"
                        )
                        _on_confirm, _on_cancel = self._build_confirm_cancel_callbacks()
                        self._append_to_popup = False
                        self._preview_panel.show_interactive(
                            full_text,
                            self._main_thread_queue,
                            on_confirm=_on_confirm,
                            on_cancel=_on_cancel,
                            title=s_ui["edit_confirm_title"],
                        )
                        log_info("Buffered finalization: show_interactive queued on main thread")
                    # Cleanup submitted here, AFTER show_interactive, so is_processing
                    # stays True until the popup is actually visible.
                    self._submit_for_main_thread(self._do_finish_cleanup)

            # Cleanup responsibility by path:
            #   normal  — chunk_worker submits _do_finish_cleanup when its loop exits
            #   timeout — chunk_worker submits cleanup when it eventually finishes
            #   buffered — cleanup submitted inline above, after show_interactive
            # Nothing to submit here.
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
            context = build_initial_prompt(self.config)

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

            try:
                text = self.transcriber.transcribe_file(
                    file_path,
                    initial_prompt=context,
                    allowed_languages=allowed_languages,
                )
            except FileTranscriptionError as fte:
                _file_notify_timer.cancel()
                log_error(f"File transcription error: {fte}")
                self.notify("Ошибка открытия файла", str(fte))
                self._submit_for_main_thread(self._do_finish_cleanup)
                return

            _file_notify_timer.cancel()

            self._last_transcription_time = time.time()

            if text and self.config.get("ai_editor_enabled", False):
                backend = self.config.get("ai_editor_backend", "local")
                is_gemini = backend == "gemini"
                active_editor = (
                    self.gemini_editor
                    if is_gemini and self.gemini_editor and self.gemini_editor.is_ready()
                    else self.ai_editor
                    if not is_gemini and self.ai_editor and self.ai_editor.is_ready()
                    else None
                )
                if active_editor is not None:
                    text = active_editor.refine_file_text(text, languages=allowed_languages)

            if text:
                log_info(f"File transcription successful, {len(text)} chars.")

                from pathlib import Path
                src = Path(file_path)
                base = Path.home() / "Downloads" / f"{src.stem}_transcription"
                output_file = base.with_suffix(".md")
                counter = 2
                while output_file.exists():
                    output_file = base.parent / f"{base.name}_{counter}.md"
                    counter += 1

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
        """Periodic check: clear MLX cache and optionally ping the model to stay warm."""
        try:
            elapsed = time.time() - self._last_transcription_time
            under_pressure = self._is_memory_pressure_high()

            if elapsed < KEEP_ALIVE_INTERVAL_SECONDS and not under_pressure:
                log_info(
                    f"Keep-alive: last transcription {elapsed:.0f}s ago, "
                    "model still warm — skipping ping."
                )
                return

            # Always clear the MLX Metal cache — this releases unused Metal buffers
            # back to the OS and is the primary defence against the child process
            # growing from ~2 GB to 6+ GB under sustained use.
            # clear_cache() only frees buffers not currently referenced by any live
            # tensor, so it is safe to call at any time between transcriptions.
            threading.Thread(
                target=self._do_keep_alive_warmup,
                kwargs={"skip_prewarm": under_pressure},
                daemon=True,
            ).start()
        except Exception as e:
            log_exception(f"Keep-alive tick error: {e}")
        finally:
            self._schedule_keep_alive()

    def _do_keep_alive_warmup(self, *, skip_prewarm: bool = False) -> None:
        """Clear MLX Metal cache and optionally pre-warm the model.

        clear_cache() is always sent — it releases Metal buffers from MLX's internal
        caching allocator and is the main mechanism preventing memory growth.
        pre_warm() is skipped under memory pressure because it loads data into memory;
        skipping it avoids adding load when the system is already constrained.
        """
        if not self._keep_alive_lock.acquire(blocking=False):
            log_info("Keep-alive: previous warmup still running — skipping.")
            return
        try:
            self.transcriber.clear_cache()
            if skip_prewarm:
                log_info(
                    "Keep-alive: memory pressure high — cache cleared, pre_warm skipped."
                )
            else:
                self.transcriber.pre_warm()
                log_info("Keep-alive: cache cleared and pre_warm() sent to transcriber process.")
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

    def _restart_transcriber_for_memory(self) -> None:
        """Restart the transcriber child process to reset accumulated MLX memory.

        clear_cache() only frees unreferenced Metal buffers. The model weight tensors
        (WhisperTranscriber._model) are always referenced and never freed. After many
        sessions the child grows to 6+ GB; a full restart brings it back to ~2 GB.
        Called in a daemon thread so it does not block the main thread.
        """
        if self.is_recording or self.is_processing:
            log_info("Transcriber restart skipped: session in progress.")
            return
        log_info(
            f"Restarting transcriber for memory reset "
            f"(session {self._completed_sessions} of {TRANSCRIBER_RESTART_AFTER_SESSIONS})."
        )
        try:
            self.transcriber._restart_process()
            # Immediately pre-warm to reload model weights into GPU before next hotkey.
            # Force-bypass the idle threshold: after restart _last_transcribe_returned_at
            # is stale (still the time of the last transcription before restart), so the
            # idle guard might wrongly skip pre_warm. Reset it to a distant past value.
            self.transcriber._last_transcribe_returned_at = 0.0
            self.transcriber.pre_warm()
            log_info("Transcriber restarted and pre_warm sent.")
        except Exception as e:
            log_error(f"Transcriber restart failed: {e}")

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

    def _send_memory_pressure_notification(self) -> None:
        """Send a system notification when AI editor is skipped due to memory pressure.

        Called on the main thread via _submit_for_main_thread so it doesn't race
        with the interactive popup appearing at the same moment.
        """
        send_notification(
            "Click-n-speak",
            "AI-редактор пропущен",
            "Нехватка памяти. Закройте лишние приложения для ускорения работы.",
        )

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
