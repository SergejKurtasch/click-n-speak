# Click-n-speak — Project Map for Codex

## What it does
macOS menu-bar app: press hotkey → record speech → Whisper transcribes → optional LLM cleanup → edit popup appears → confirm → text injected into active app.

---

## Process architecture

```
Main thread (rumps/AppKit event loop)
  └─ drains _main_thread_queue every 0.3s (all UI ops MUST go through this queue)

Hotkey thread (pynput)
  └─ toggle_recording() → spawns stop_recording_and_process thread

Audio stream thread (sounddevice callback)
  └─ _callback() → triggers chunk via chunk_callback

Chunk worker thread (per session)
  └─ chunk_worker() → calls process_chunk() → calls transcriber.transcribe() (blocks)

Transcriber child process (multiprocessing)
  └─ _run_loop(): processes input_queue serially (warmup / prewarm / transcribe)
  └─ results → output_queue
  └─ parent-death watchdog (kqueue + PPID poll) — hard-exits if parent dies

AI Editor thread (per refinement call)
  └─ AiEditor.refine() spawns daemon thread with 8s timeout (local Qwen); Gemini uses longer HTTP timeout
  └─ Uses same MLX GPU as Whisper — protected by non-blocking lock (skipped under memory pressure only for local MLX, not for ExternalApiEditor backends)

Setup wizard (main thread, first launch only)
  └─ run_setup_wizard() → _run_wizard() → NSAlert sequence
  └─ Polls for permission changes via NSRunLoop spin loop (0.5s ticks)
  └─ Scheduled via menu_bar.schedule_setup_wizard() after NSApp is live

ModelDownloader child process (per download, at most one active)
  └─ ModelDownloader.start() → spawns child process running _subprocess_download()
  └─ _subprocess_download: snapshot_download() with _Tqdm (tqdm replacement, byte-level progress)
  └─ monitor thread drains progress_q / result_q; cancel() terminates the child process
  └─ on_progress fires into _main_thread_queue (throttled, ≥0.2s apart)
  └─ on_error / on_cancelled post _apply_error / _apply_cancel closures to
     _main_thread_queue — download thread never writes _download_state/_download_progress directly
  └─ on_done posts _on_download_complete to _main_thread_queue
```

---

## Module map

| File | Responsibility | Key classes/functions |
|---|---|---|
| `main.py` | Entry point, wires everything up | `main()` |
| `src/app.py` | Core state machine, orchestrates all modules; metrics snapshot + notifications; passes vocab hints to API editors | `SVoiceRecApp`, `run_metrics_if_due()`, `run_daily_maintenance_if_due()`, `flush_dirty_config_if_needed()` |
| `src/recorder.py` | Audio capture + VAD-based chunking | `AudioRecorder` |
| `src/transcriber.py` | Whisper via MLX in child process | `TranscriberProcessWrapper`, `WhisperTranscriber` |
| `src/ai_editor.py` | LLM post-processing — local (Qwen 2.5 1.5B 4-bit) or Gemini API; API backends share `ExternalApiEditor` and accept optional dictionary hints in the system prompt | `AiEditor`, `ExternalApiEditor`, `GeminiEditor`, `get_gemini_api_key()`, `set_gemini_api_key()`, `refine_file_text()` |
| `src/preview_panel.py` | HUD popup (NSPanel) — non-interactive + interactive modes; context menu **Add to Dictionary** (⌘D) on `DictionaryAwareTextView` | `TranscriptionPreviewPanel`, `append_text()` |
| `src/suggestions_panel.py` | Resizable NSWindow for reviewing pending candidates; scrollable checkbox list | `SuggestionsPanel` |
| `src/menu_bar.py` | rumps menu bar, settings; Permissions submenu; Initial Prompt submenu includes **Statistics…**; hourly daily maintenance + 60s dirty-config flush timers | `ClickNSpeakApp` |
| `src/hotkey_handler.py` | pynput global hotkey listener | `HotkeyHandler`, `CompatGlobalHotKeys` |
| `src/injector.py` | Types text into active app via pynput | `inject_text()` |
| `src/permissions.py` | macOS TCC permission checks and requests | `check_accessibility()`, `check_input_monitoring()`, `check_microphone()`, `all_permissions_granted()`, `is_setup_done()`, `mark_setup_done()` |
| `src/setup_wizard.py` | First-launch NSAlert wizard for all permissions | `run_setup_wizard()`, `is_wizard_active()` |
| `src/utils.py` | Logging, config paths, notifications, UI strings, language helpers, term metadata helpers, atomic text writes | `setup_logging()`, `get_config_path()`, `get_allowed_languages()`, `get_language_script()`, `target_lang_for_script_bucket()`, `get_metrics_history_path()`, `write_text_atomic()`, `build_initial_prompt()`, `migrate_config_to_v5()`, `update_term_usage()`, `apply_decay()`, `_term_str()`, `_term_is_active()` |
| `src/phrase_history.py` | Append-only phrase log (TSV) | `append_phrase()`, `get_last_phrases()`, `count_phrases()` — cached via `_phrase_count` |
| `src/dataset_logger.py` | JSONL dataset for fine-tuning | `append_to_dataset()` — records `ai_status` field per entry |
| `src/metrics.py` | Dictionary/quality metrics from dataset + corrections + config; daily history snapshots (JSONL append + optional rotation) | `compute_metrics()`, `append_metrics_history()`, `load_metrics_history()` |
| `src/vocab_provider.py` | Feeds external API editors: ranked known terms from `user_terms`, misrecognition pairs from `corrections.json`; popup **Add to Dictionary** inserts via `add_term_to_user_terms()` | `collect_known_terms()`, `collect_misrecognitions()`, `add_term_to_user_terms()` |
| `src/correction_analyzer.py` | Extracts correction-driven term candidates from user edits; `corrections.json` uses script buckets `latin`/`cyrillic` (schema v2) | `update_corrections_index()`, `get_correction_candidates()`, `has_fresh_strong_correction_signal()` |
| `src/log_analyzer.py` | Phrase-history vocabulary candidates (`latin`/`cyrillic` script buckets); merge/remap in `app.py` uses `get_language_script()` | `get_frequent_terms()`, `get_prompt_candidates()` |
| `src/updater.py` | GitHub releases update check | `check_for_update()` |
| `src/process_watchdog.py` | Kills transcriber child when parent dies (kqueue + PPID poll); reaps orphans at startup | `install_parent_death_watchdog()`, `sweep_orphan_children()`, `ensure_own_process_group()` |
| `src/model_downloader.py` | HuggingFace model download in child process (spawn) with progress callbacks and cancel support | `ModelDownloader`, `_subprocess_download` |
| `src/model_download_panel.py` | NSPanel with progress bar, speed/ETA readout, and Cancel button for in-app model downloads | `ModelDownloadPanel` |

---

## Session state machine (`SVoiceRecApp`)

```
IDLE
  │  hotkey press
  ▼
RECORDING  (is_recording=True)
  │  audio chunks → chunk_queue (via on_chunk_received)
  │  chunk_worker processes non-final chunks → update_text in panel
  │  hotkey press again (or silence trigger)
  ▼
PROCESSING (is_processing=True, is_recording=False)
  │  stop_recording_and_process() in background thread
  │  chunk_worker drains queue, transcribes final chunk
  │  process_chunk(is_final=True) → show_interactive popup
  ▼
POPUP OPEN (interactive NSPanel, is_processing=False)
  │  user edits text, presses Enter
  │  context menu / ⌘D — Add to Dictionary (validated token → `user_terms` by script bucket)
  │  _on_confirm → _run_injection thread → restores focus → inject_text
  │  OR user presses Escape → _on_cancel
  │  OR hotkey press → RECORDING again (_append_to_popup=True)
  │      └─ new transcription appended via preview_panel.append_text()
  │         _previous_app_pid preserved; popup stays open
  ▼
IDLE  (_do_finish_cleanup on main thread)
```

### Key state flags
| Flag | Type | Meaning |
|---|---|---|
| `is_recording` | bool | Audio stream active |
| `is_processing` | bool | Worker running or processing; blocks new recordings |
| `_session_id` | int | Increments on each `start_recording()`; worker checks this before showing popup to avoid stale injection |
| `stop_worker` | threading.Event | Set when stop is requested; worker drains queue then exits |
| `_append_to_popup` | bool | Set when hotkey fires while popup is open; causes new transcription to append instead of replacing |

---

## Critical thread-safety rules

- **All NSPanel/UI calls must go through `_submit_for_main_thread()`** which puts them in `_main_thread_queue`, drained on main thread by rumps 0.3s timer.
- **Exception:** `preview_panel.update_status(text, queue)` accepts `_main_thread_queue` as a parameter and dispatches AppKit operations internally — safe to call from worker threads.
- `chunk_worker` and `process_chunk` run on the worker thread — they only touch `self.transcribed_parts`, `self._session_id`, and queue jobs to main thread.
- `transcriber.transcribe()` is a **blocking call** — it waits for the child process to respond. The child process is single-threaded and serializes all requests.
- `AiEditor.refine()` uses a non-blocking lock — if a previous LLM call is still running, refinement is skipped entirely (Metal GPU conflict avoidance). `last_refine_status` is set in every code path (`ok`/`unchanged`/`timeout`/`skipped`/`error`/`disabled`).
- `GeminiEditor` (and any future `ExternalApiEditor`) uses the same non-blocking lock pattern. On timeout the lock stays held by the daemon thread until the HTTP request finishes — preventing concurrent API calls. Uses `REFINE_STATUS_SKIPPED` (not `DISABLED`) when the lock is busy.
- **Memory-pressure skip** applies only to the local MLX `AiEditor`, not to `ExternalApiEditor` — cloud backends do not contend for the Whisper GPU weights.
- **`update_term_usage()`** runs on the main thread (`_apply_term_usage_on_main` via `_submit_for_main_thread` after injection); `_config_usage_dirty` is flushed by `flush_dirty_config_if_needed()` on a 60s menu-bar timer and before periodic transcriber restarts.
- **Prompt analysis commits** (`auto` / `suggest` branches that mutate `user_terms` / `pending_suggestions` and sync Initial Prompt `.txt` via `_sync_prompt_file`) run inside closures posted to `_main_thread_queue` so config + on-disk prompt files stay main-thread owned.
- `refine_file_text()` (both editors) uses a **blocking** lock acquire (timeout=10s) and runs synchronously in the `_file_transcription_worker` thread — no 8s realtime cap. Local: splits at sentence boundaries if text > ~40 K chars (half of Qwen's 32 K-token context). Gemini: sends full text, 5-min timeout.
- `get_allowed_languages()` in `utils.py` normalises internal lang codes to ISO 639-1 via `_WHISPER_LANG_CODE` before passing to Whisper (e.g. `"ua"` → `"uk"`). When adding a new language with a non-standard internal code, add a mapping there.
- `get_gemini_api_key()` / `set_gemini_api_key()` read/write the Gemini API key from env vars (`GOOGLE_API_KEY`, `GOOGLE_GENAI_API_KEY`) or macOS Keychain (`click-n-speak` / `google_api_key`). Keychain writes call `/usr/bin/security` via subprocess.
- `save_config_to_disk()` writes atomically via sibling tmp file + `os.replace` + `fsync` — `config.json` is never corrupted by SIGKILL mid-write.
- `chunk_queue.put_nowait()` is used throughout — never the blocking `put()` — to avoid deadlocking the stop sequence.
- **`ModelDownloader` callbacks never mutate `_download_state`/`_download_progress` directly** — `on_error` and `on_cancelled` post `_apply_error`/`_apply_cancel` closures to `_main_thread_queue`. The guard in `_start_whisper_model_download` iterates `WHISPER_MODELS` (constant list), not `_download_state.values()`, to avoid `RuntimeError` from concurrent `.pop()`.
- `_call_mlx_transcribe()` sets `HF_HUB_OFFLINE=1` around every `mlx_whisper.transcribe()` call and restores the previous value in `finally` — prevents the transcriber child from triggering a network download mid-transcription when mlx_whisper probes for model updates.
- On macOS 15+, **never auto-start pynput listener after permission grant** — `TSMGetInputSourceProperty` crashes unless the process was started with permissions already held. Require app restart instead.

---

## Chunking logic (`recorder.py`)

Audio is split into chunks using VAD (webrtcvad) with adaptive thresholds:

| Phase | Condition | Silence threshold to trigger send |
|---|---|---|
| Early | `duration < target_speech_duration` (4s) | 1.0s (normal pause) |
| Target reached | `4s ≤ duration < max` (8s) | 0.4s (micro-pause) |
| Max reached | `duration ≥ max_speech_duration` (8s) | 0s (force send on any silence frame) |

Defaults: `target=4.0s`, `max=8.0s`. Configurable via `config.json` or menu.

---

## Transcription pipeline (per chunk)

```
audio_chunk (numpy float32, 16kHz)
  → TranscriberProcessWrapper.transcribe()  [blocking, 30s timeout]
    → guard: final chunk ≤0.5s (8000 samples) → skipped (boundary artefact)
    → guard: non-final chunk <3s + RMS silent (_is_audio_silent) → skipped (avoids 14-22s tail-decode)
    → child process: WhisperTranscriber.transcribe()
      → mlx_whisper.transcribe()  [HF_HUB_OFFLINE=1 set; signature probed once via inspect]
      → hallucination filter (phrase list, word repetition, CJK chars, _SUBWORD_REPEAT_RE)
      → language filter (retry with silence padding if wrong language)
  → text returned to chunk_worker
  → [if final + ai_editor_enabled] AiEditor / GeminiEditor.refine()  [8s local timeout; Gemini separate HTTP timeout]
  → accumulated in self.transcribed_parts
  → [if not final] preview_panel.update_text()
  → [if final] preview_panel.show_interactive()
```

---

## GPU warmup strategy

| Trigger | Method | Effect |
|---|---|---|
| App startup | `start_model_warmup()` → `transcriber.warmup()` | One-time silence transcription in child process |
| Every 15 min (or any tick under memory pressure) | `_keep_alive_tick()` → `_do_keep_alive_warmup()` | `clear_cache()` always; `pre_warm()` only when no memory pressure |
| After every transcription | `_run_loop` (child process) | `mlx.core.metal.clear_cache()` + `gc.collect()` — releases mel/attention/logit Metal buffers immediately |
| macOS wake from sleep | `start_wake_observer()` | Triggers `_do_keep_alive_warmup()` |
| Each hotkey press | `start_recording()` → `transcriber.pre_warm()` | Real silence transcription bypassing `_warmup_done` guard; **skipped** if last transcription returned < 45s ago (`_last_transcribe_returned_at`) |
| Every 20 completed sessions | `_do_finish_cleanup()` → `_restart_transcriber_for_memory()` (daemon thread) | Full child-process restart + immediate `pre_warm()`; resets model weight tensors that `clear_cache()` cannot free |

---

## Permissions flow (`permissions.py` + `setup_wizard.py`)

Three TCC permissions required:

| Permission | Check | Purpose |
|---|---|---|
| Microphone | `check_microphone()` via AVFoundation | Audio recording |
| Accessibility | `check_accessibility()` via AXIsProcessTrusted | Text injection + hotkey |
| Input Monitoring | `check_input_monitoring()` via CGEventTap | Global hotkey (macOS 15+) |

**First-launch wizard:** `main.py` calls `menu_app.schedule_setup_wizard()` if `not is_setup_done() or not all_permissions_granted()`. The wizard runs on the main thread as a sequential NSAlert flow. While waiting for the user to toggle a permission in System Settings, it spins the NSRunLoop in 0.5s ticks (never blocks the main thread).

**Setup-done flag:** `~/Library/Application Support/Click-n-speak/setup_done` — presence means wizard was completed. Only written on successful completion or explicit user skip; never written on exception.

**Input Monitoring fast-check:** `check_input_monitoring_fast()` reads TCC.db via sqlite3 to avoid triggering the system dialog prematurely. Filters by `client='com.sergej.clicknspeak' OR client LIKE '%python%'`. Falls back to `False` if DB is inaccessible (SIP).

**Menu bar live status:** `ClickNSpeakApp` tracks all three permissions (`_microphone_ok`, `_accessibility_granted`, `_input_monitoring_ok`) and reflects them in the Permissions submenu. `_refresh_permissions()` is called on every menu open via `_MainMenuDelegate` (NSMenuDelegate); also called once at startup via `_run_wizard_if_pending`. Opening any permission pane calls `_activate_system_settings()` to bring System Settings to front.

---

## Process lifecycle (`process_watchdog.py`)

macOS has no `PR_SET_PDEATHSIG`, so a multiprocessing child holding 2–4 GB of
MLX weights can outlive its parent on SIGKILL / Force Quit / segfault. Three
independent safety nets prevent orphan accumulation across sessions:

| Layer | Where | What it covers |
|---|---|---|
| **kqueue watcher** (primary) | `install_parent_death_watchdog()` in child | Kernel-level `NOTE_EXIT` on parent PID; fires within ~10 ms |
| **PPID poller** (fallback) | same function, 2s interval | Catches reparenting to launchd if kqueue ever fails |
| **Startup sweep** | `sweep_orphan_children()` in `main.py` | Finds `multiprocessing.spawn_main` / `resource_tracker` helpers whose PPID is 1 and whose cmdline contains `Click-n-speak`, kills them before a new session loads its own models |

Supporting mechanisms in `main.py`:

- `ensure_own_process_group()` — moves main into its own PGID before spawning any child, so `os.killpg(os.getpgrp(), SIGKILL)` reaches every descendant (including `resource_tracker`, which doesn't inherit our watchdog).
- Signal handlers (`SIGTERM`, `SIGINT`, `SIGHUP`, `SIGQUIT`) run full cleanup and then `killpg` — `SIGABRT` is intentionally unhandled (fatal assertion paths typically deadlock on re-entry).
- `sys.excepthook` and `threading.excepthook` route uncaught exceptions through the same cleanup + `killpg` path; `SystemExit` / `KeyboardInterrupt` subclasses are treated as cooperative exits, not crashes.
- `install_nsapp_terminate_observer()` subscribes to `NSApplicationWillTerminateNotification` so rumps' built-in Cmd+Q (which calls `NSApp.terminate:` directly) still triggers our cleanup before AppKit tears the process down. Idempotent — the ObjC observer class is defined once at module level.
- Single-instance guard: `fcntl.flock` on `~/Library/Application Support/Click-n-speak/.instance.lock`. The OS releases the lock on process death, so a crashed prior session is auto-reclaimed.

**Test coverage:** `tests/test_process_watchdog.py` simulates Force Quit on the parent (SIGKILL) and verifies both the multiprocessing worker and the stdlib `resource_tracker` helper die within ~5 s. The `resource_tracker` case is a regression guard against future stdlib changes that could break the PGID kill path.

---

## Test execution policy

- Before running any `pytest`/test command, activate project venv:
  `source venv/bin/activate`
- If `venv` is missing or activation fails, do not run tests; report blocker.
- Prefer combined command form:
  `source venv/bin/activate && python -m pytest ...`

---

## Config (`config.json`)

Stored at root in dev mode; copied to `~/Library/Application Support/Click-n-speak/config.json` on first `.app` launch.

### v5 schema (current — after all migrations)

```json
{
  "schema_version": 5,
  "primary_language": "ru",
  "additional_languages": ["en"],
  "initial_prompt": "...",
  "user_terms": {
    "ru": [
      {"term": "термин1", "source": "manual", "added_at": "2026-01-01T...", "last_seen": "2026-05-07T...", "use_count": 12},
      {"term": "нейросеть", "source": "auto",  "added_at": "2026-03-01T...", "last_seen": "2026-05-01T...", "use_count": 4}
    ]
  },
  "prompt_snapshots": {"ru": [...]},
  "pending_suggestions": {"en": [{"term": "MLX", "count": 7}]},
  "skipped_terms": {"en": {"mlx": 1042}},
  "prompt_update_mode": "suggest",
  "auto_prompt_check_interval": 20,
  "auto_prompt_check_min_count_primary": 10,
  "auto_prompt_check_min_count_additional": 5,
  "auto_prompt_lookback": 300,
  "last_analysis_phrase_count": 0,
  "last_decay_run_ts": null,
  "max_dictionary_age_days": 60,
  "ai_editor_enabled": true,
  "ai_editor_backend": "local",
  "ai_editor_model": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
  "gemini_model": "gemini-2.5-flash-lite",
  "model_name": "mlx-community/whisper-large-v3-turbo",
  "silence_duration": 1.0,
  "target_speech_duration": 4.0,
  "max_speech_duration": 8.0,
  "min_speech_duration": 1.0,
  "autostart": false,
  "last_metrics_snapshot_ts": null,
  "notify_on_metrics": true,
  "last_metrics_notification_ts": null
}
```

**Per-term fields (v5):**

| Поле | Тип | Назначение |
|---|---|---|
| `term` | str | Само слово |
| `source` | `"manual"` / `"auto"` / `"correction"` | Источник. Manual вечны — decay не трогает. |
| `added_at` | ISO datetime | Когда добавлено |
| `last_seen` | ISO datetime | Последнее обнаружение в phrase; обновляется `update_term_usage()` |
| `use_count` | int | Число появлений в фразах. Тай-брейк при сортировке в prompt. |
| `inactive` | bool (опционально) | `True` = деактивировано decay; пропускается в `build_initial_prompt`. Снимается автоматически при следующем `update_term_usage`. |

**Key semantics:**
- `user_terms[lang]` — все термины (ручные + принятые из авто-анализа); v5 — список dict вместо str
- `prompt_snapshots[lang]` — один шаг undo для `user_terms` (может быть list[str] для legacy snapshots)
- `pending_suggestions` — кандидаты, ожидающие ревью (режим suggest)
- `skipped_terms[lang][lower]` — номер фразы, на которой термин был отклонён; cooldown **150** фраз
- `prompt_update_mode` — `"suggest"` / `"auto"` / `"disabled"`
- `auto_prompt_check_interval` — каждые N фраз запускать авто-анализ (default **20**)
- `auto_prompt_check_min_count_primary` / `auto_prompt_check_min_count_additional` — пороги по скрипту (default **10** primary / **5** additional)
- `auto_prompt_lookback` — сколько последних строк `phrase_history.txt` учитывает анализ (default **300**)
- `last_analysis_phrase_count` — счётчик фраз на момент последнего анализа
- `last_decay_run_ts` — ISO datetime последнего запуска `apply_decay()`; раз в 24 h
- `max_dictionary_age_days` — порог устаревания для decay (default **60** дней)
- `last_metrics_snapshot_ts` — ISO datetime последнего снимка `compute_metrics()` (не чаще раза в 24 h в `run_metrics_if_due`, кроме `force=True` / меню Statistics)
- `notify_on_metrics` — если `true`, при резком росте edit-score относительно 90-дневного минимума возможна редкая (≤ раз в 30 дней) подсказка через `send_notification` (`last_metrics_notification_ts` хранит throttle)

`initial_prompt` строится автоматически через `build_initial_prompt(config)` и **не редактируется напрямую**. Термины сортируются: manual → correction → auto (use_count desc); inactive пропускаются.

**Migration chain:** `migrate_config_to_v2` → `migrate_config_to_v3` → `migrate_config_to_v4` → `migrate_config_to_v5` (list[str] → list[dict], все старые термины получают `source="manual"`).

---

## UI flow — main-thread queue

All NSPanel calls are posted as `(fn, args, kwargs)` tuples to `_main_thread_queue`. Drained every 0.3s by `_drain_main_thread_queue` in `menu_bar.py`. Never call AppKit directly from worker threads.

---

## File paths (runtime)

| Resource | Dev path | .app path |
|---|---|---|
| `config.json` | `~/Click-n-speak/config.json` | `~/Library/Application Support/Click-n-speak/config.json` |
| `phrase_history.txt` | `~/Click-n-speak/phrase_history.txt` | `~/Library/Application Support/Click-n-speak/phrase_history.txt` |
| Setup-done flag | — | `~/Library/Application Support/Click-n-speak/setup_done` |
| Log file | `~/Library/Logs/Click-n-speak.log` | same |
| Dataset | `~/.clicknspeak_dataset.jsonl` | same |
| Metrics history | `~/Click-n-speak/metrics_history.jsonl` (dev) | `~/Library/Application Support/Click-n-speak/metrics_history.jsonl` |
| Corrections index | `~/Click-n-speak/corrections.json` (dev) | `~/Library/Application Support/Click-n-speak/corrections.json` |
| Prompt files (per lang) | `~/Library/Application Support/Click-n-speak/initial_prompt_{lang}.txt` | same |
| Dev CLI `scripts/print_metrics.py` | repo `scripts/print_metrics.py` (запуск из корня с активированным venv) | — |

---

## Known latency profile

| Step | Typical | Worst case | Notes |
|---|---|---|---|
| First chunk collected | ~4-5s | ~8s | Depends on pauses in speech |
| Whisper transcription (warm) | 2-4s | 6s | Per chunk |
| Whisper transcription (cold GPU) | 15-21s | 25s | After long idle; `pre_warm()` on hotkey mitigates |
| AI Editor (Qwen 2.5 1.5B 4-bit) | 0.7-0.9s | 8s | Final chunk only; has timeout + abort fallback |
| Popup appears after stop | ~4-6s | ~20s | = queued chunks drain + last chunk + AI editor |

**Latency sources resolved (2026-04-27):**
- Queued non-final chunks are now **all processed** on stop — no longer dropped; no speech is lost.
- Short silent chunks (<3s, RMS<0.005) rejected before Whisper — avoids 14-22s tail-decode.
- Final chunks ≤0.5s (8000 samples) skipped — prevents 0.30s boundary artefact reaching Whisper.
- `pre_warm()` skipped when last transcription < 45s ago — eliminates 15-22s cold-start penalty on rapid re-recordings.

**Latency sources resolved (2026-04-29):**
- **Cold-start text loss**: first chunk of a session after 5+ min idle or under memory pressure uses extended 90s timeout (`TRANSCRIBER_COLD_START_TIMEOUT_SECONDS`) — process no longer killed before GPU weights reload.
- **AiEditor stuck thread under memory pressure**: `_is_memory_pressure_high()` check before `refine()` — LLM call skipped entirely, eliminating 10.5s stuck-thread delay; user notified via macOS system notification with advice to free memory.
- **Premature "Ready" on worker timeout**: `stop_recording_and_process` now sets "Still working…" and skips `_do_finish_cleanup` when worker exceeds 30s; `chunk_worker` always submits cleanup on exit — UI no longer resets before popup appears.

---

## Архитектура словаря (Initial Prompt)

Как `initial_prompt` строится и попадает в Whisper:

```
user_terms[primary] + user_terms[additional...]  (если есть доп. языки)
  ↓  deduplicate_prompt_terms()
  ↓  build_initial_prompt()
      → если есть термины: "Русский язык. термин1, PCA"  (500 chars cap)
      → если терминов нет: "Русский язык. Это разговорная речь. Используются профессиональные термины."
  ↓  config["initial_prompt"]  (кэш)
  ↓  process_chunk() — каждый чанк строит context из vocab_prompt + whole recent chunks
  ↓  WhisperTranscriber.transcribe(initial_prompt=context)
```

**Контекст в process_chunk (скользящее окно):**
- Бюджет ~700 символов на весь context (instruction + vocab + недавние чанки)
- Vocab всегда полный; недавние чанки добавляются целиком (newest-first) пока влезают
- Ни один чанк не обрезается посередине

**Источники обновления user_terms:**
- Попап правки: **Add to Dictionary** / ⌘D — выделение или слово под кареткой → `add_term_to_user_terms()` → язык по script bucket (`target_lang_for_script_bucket`), затем `build_initial_prompt` + `save_config_to_disk` + `_sync_prompt_file`
- `Edit...` → записывает `.txt`, watcher читает изменение → `user_terms[primary]`
- `Revert to Previous` → своп `user_terms[lang]` ↔ `prompt_snapshots[lang]`
- Авто-анализ (`_run_prompt_analysis`) каждые N фраз (default 20) → `get_prompt_candidates()` + correction merge; частотный путь использует buckets `latin`/`cyrillic`, затем remap в ISO-коды через `target_lang_for_script_bucket()`
  - Режим `auto` → `_apply_candidates_to_user_terms()` → сразу в `user_terms`
  - Режим `suggest` → в `pending_suggestions`, ждёт ревью
- Стартовый алерт "Добавить всё" → `_apply_all_pending_suggestions()`
- `SuggestionsPanel` (Review Suggestions) → принятые → `user_terms`, отклонённые → `skipped_terms`

**Канонизация термов (new-data only):**
- Единый контракт: `canonicalize_term()` (display) + `canonical_term_key()` (identity key) в `utils.py`
- Удаляется только boundary punctuation + пробелы; внутренние `+ # . _ -` сохраняются (`C++`, `node.js`, `v2.1`)
- Сохраняются семантические leading-префиксы: `.NET`, `@mention` (не срезаются как «мусорная» пунктуация)
- Применяется к новому потоку данных: `log_analyzer`, `correction_analyzer`, merge/dedupe в `app.py`, accept/reject path в `menu_bar.py`, `vocab_provider`, dictionary-side в `metrics.py`
- Legacy-данные в `user_terms` / `pending_suggestions` / `skipped_terms` не мигрируются автоматически

**External API редактор (Gemini и будущие `ExternalApiEditor`):**
- В `refine()` / `refine_file_text()` передаются `known_terms` (`collect_known_terms`) и `misrecognitions` (`collect_misrecognitions` из `corrections.json`, пары с `count ≥ 3`) — доп. блоки в system prompt, чтобы не «исправлять» осознанный словарь и чаще попадать в частые замены Whisper→финал

**Синхронизация `.txt` с конфигом:**
- Запись списков терминов в `initial_prompt_{lang}.txt` через `write_text_atomic()` (tmp + replace)
- `_watch_prompt_file`: пустой файл при непустых `user_terms[lang]` игнорируется (защита от оборванной записи)

**Переключение режима:**
- "Auto-update Mode ▶" подменю в меню → `prompt_update_mode` = `"suggest"` / `"auto"` / `"disabled"`

**Ротация словаря (decay):**
- `update_term_usage(config, phrase)` — после инжекции планируется на главный поток (`_apply_term_usage_on_main`); при изменении счётчиков `_config_usage_dirty = True` (сброс на диск по таймеру 60 s / перед рестартом транскрайбера)
- `apply_decay(config, max_age_days=60)` — помечает `inactive=True` термины с `source != "manual"` у которых `last_seen > cutoff` и `use_count < 3`; manual вечны
- `run_decay_if_due()` в `SVoiceRecApp` — запускает decay раз в 24 h; вызывается из `ClickNSpeakApp._decay_tick` через `run_daily_maintenance_if_due()` (`@rumps.timer(3600)`)
- `run_metrics_if_due()` в `SVoiceRecApp` — считает метрики раз в 24 h и пишет `metrics_history.jsonl`; вызывается тем же hourly tick через `run_daily_maintenance_if_due()`
- «Manage Terms…» в подменю Initial Prompt — NSAlert со статистикой + кнопка «Удалить неактивные»
- Реактивация автоматическая: при следующем `update_term_usage` совпадение снимает `inactive` без участия пользователя

---

## Roadmap

### ✅ Etap 1 — v2 Config Schema (commit fcd6e10)
- Новые поля: `user_terms`, `auto_terms`, `prompt_snapshots`, `pending_suggestions`,
  `skipped_terms`, `prompt_update_mode`, `auto_prompt_check_interval`, `last_analysis_phrase_count`
- `migrate_config_to_v2()` в `utils.py` — однократная миграция из v1 (парсит `custom_prompts`)
- `build_initial_prompt()` включает термины всех активных языков

### ✅ Etap 2 — Фильтры log_analyzer (anti-error-loop)
- `_TERM_PATTERN` начинается с буквы; `_TERM_STOPLIST` (http/the/and/…)
- `_levenshtein()` с early-exit при расстоянии > 2
- `_collect_english_terms()`: требует ≥2 сессий, нормализует регистр, фильтрует URL-токены
- `_filter_near_duplicates()`: убирает пары с расстоянием ≤1, оставляет более частый
- `_collect_russian_bigrams()`: только биграммы (не триграммы), порог ≥3
- `blacklist` параметр в `get_frequent_terms()`

### ✅ Etap 3 — Авто-анализ каждые N фраз
- `get_prompt_candidates()` в log_analyzer: топ кандидатов из последних 100 фраз, мин. 5 вхождений,
  cooldown 100 фраз для отклонённых, cap 20 на язык, раздельные бакеты EN/RU
- `_apply_candidates_to_auto_terms()` helper в app.py; `_maybe_trigger_prompt_analysis()` +
  `_run_prompt_analysis()` в `SVoiceRecApp`; триггер после каждого `append_phrase`
- `SuggestionsPanel` (`src/suggestions_panel.py`): NSWindow, чекбоксы + badge-счётчик,
  пагинация "Показать ещё 10", 3 кнопки (Авто / Позже / Добавить)
- `menu_bar.py`: `_suggest_item` с badge, `_check_pending_suggestions_on_startup()`,
  `_show_suggestions_alert()` (NSAlert, 3 кнопки), `_open_suggestions_panel()`,
  `update_suggest_menu_badge()`

---

### ✅ Etap 4 — UI управления режимом + просмотр auto_terms
- "Update from History" убран из меню (метод оставлен до Etap 6)
- "Auto-update Mode ▶" подменю с 3 checkmark-items: Suggest / Auto / Disabled;
  клик вызывает `_on_set_update_mode(mode)` → меняет `prompt_update_mode`, сохраняет config
- `_update_mode_submenu_state()` синхронизирует checkmarks при init и смене режима
- "Manage Auto Terms…" → NSAlert показывает `auto_terms[lang]` по языкам;
  кнопка "Очистить всё" сбрасывает все `auto_terms[lang] = []` и перестраивает `initial_prompt`
- Файл: `src/menu_bar.py`

---

### ✅ Etap 5 — Редактирование терминов для дополнительных языков
- `_edit_prompt_for_lang(lang)` — общий helper; `edit_initial_prompt` вызывает его для primary
- `_rebuild_edit_terms_item()` — переключает "Edit…" (single) ↔ "Edit Terms ▶" submenu (multi)
  через rumps `.hidden`; вызывается при init, смене primary, добавлении/удалении additional
- `_watch_prompt_file` — итерирует все активные языки, `_prompt_mtimes` dict вместо single-var
- `_apply_primary_language` / `_apply_additional_language` — вызывают `_rebuild_edit_terms_item()`
- Файл: `src/menu_bar.py`

---

### ✅ Etap 6 — Удаление legacy-кода
- `generate_terms_hint_from_history()` удалена из `log_analyzer.py`
- `_migrate_old_prompt()` (stub `pass`) и вызов удалены из `menu_bar.py`
- `update_initial_prompt_from_history()` удалена из `menu_bar.py` (убрана из меню ещё в Etap 4)
- Legacy-ветка `else: legacy = config.get("initial_prompt")` удалена из `build_initial_prompt()` в `utils.py`
- `assets/prompts/` (sample `.txt`) удалены; запись в File paths обновлена на runtime-путь config-dir
- **Файлы:** `src/log_analyzer.py`, `src/menu_bar.py`, `src/utils.py`, `AGENTS.md`

---

### ✅ Etap 8 — Надёжность и производительность (9 fixes, commit b16618b)
- `hallucination_phrases` используют word-boundary regex — реальные слова больше не дропаются
- `preview_panel`: убран глобальный `NSEvent` монитор; `activateIgnoringOtherApps_` гарантирует фокус
- `save_config_to_disk()`: атомарная запись через tmp + `os.replace` + `fsync`
- `phrase_history._phrase_count` cache — O(1) вместо O(n) скана файла в hotpath инжекции
- `recorder`: `del vad_buffer[:n]` вместо slice-assignment — O(1) в real-time callback
- `build_initial_prompt()`: обрезка по BPE-токенам (лимит 200/224) вместо символов — Whisper больше не переполняется Кириллицей
- `transcribed_parts.append` перенесён после проверки `session_id` — stale-worker не загрязняет новую сессию
- mlx_whisper сигнатура зондируется один раз через `inspect` вместо повторного вызова на `TypeError`
- **Файлы:** `src/app.py`, `src/log_analyzer.py`, `src/phrase_history.py`, `src/preview_panel.py`, `src/recorder.py`, `src/transcriber.py`, `src/utils.py`

---

### ✅ Etap 9 — Дренаж очереди + RMS pre-filter + subword-repeat (commit 92ca336)
- `app.py`: все накопленные non-final чанки обрабатываются при stop — больше не дропаются
- `transcriber.MIN_FINAL_CHUNK_SAMPLES`: 4800 → 8000 (0.3s → 0.5s); `<` → `<=` — граничный артефакт не достигает Whisper
- `_is_audio_silent()`: RMS pre-filter для коротких (<3s) non-final чанков — отклоняет за микросекунды вместо 14-22s
- `_SUBWORD_REPEAT_RE`: стрипает внутрисловные петли (oiseoiseoiseoise...) — то, что `_collapse_consecutive_word_repetition` пропускает
- **Файлы:** `src/app.py`, `src/transcriber.py`

---

### ✅ Etap 10 — Pre-warm skip + AI editor status tracking (commit 46cc6b4)
- `TranscriberProcessWrapper._last_transcribe_returned_at`: `pre_warm()` пропускается если последняя транскрипция < 45s назад — устраняет 15-22s штраф при быстром повторе
- Child `_run_loop`: prewarm проверяет `input_queue.empty()` — реальный чанк не блокируется за прогревом
- `_REFINE_TIMEOUT_SECONDS`: 15.0 → 8.0 — успешные рефайны занимают 0.7-3s; 8s достаточно
- `AiEditor.last_refine_status`: устанавливается во всех путях (`ok`/`unchanged`/`timeout`/`skipped`/`error`/`disabled`)
- `dataset_logger`: новое поле `ai_status` в JSONL записях
- **Файлы:** `src/ai_editor.py`, `src/app.py`, `src/dataset_logger.py`, `src/transcriber.py`

---

### ✅ Etap 7 — Унификация auto_terms + качество Initial Prompt
- `auto_terms` удалён: принятые кандидаты теперь идут в `user_terms[lang]`; `migrate_config_to_v3()` мёржит существующие `auto_terms`
- `migrate_config_to_v4()` в `utils.py`: чистит артефакт v2-миграции (языковые хинты внутри термина)
- `LANG_DEFAULT_CONTEXT` в `utils.py`: дефолтные стилевые фразы для каждого языка (ru/en/de/es/fr); включаются в `build_initial_prompt()` когда `user_terms` пуст
- `process_chunk()` в `app.py`: скользящее окно — vocab_prompt всегда полный, недавние чанки добавляются целиком (newest-first) в рамках бюджета ~700 символов
- **Файлы:** `src/utils.py`, `src/app.py`, `AGENTS.md`

---

### ✅ Etap 3b — Ротация словаря: schema v5 + decay (commit a8826de)
- `migrate_config_to_v5()`: `user_terms[lang]` list[str] → list[dict] с полями `term/source/added_at/last_seen/use_count`; старые строки → `source="manual"` (защищены от decay)
- `_term_str()` / `_term_is_active()` — хелперы прозрачного доступа к str и dict записям; используются везде где итерируется `user_terms`
- `build_initial_prompt()`: пропускает `inactive=True`; сортировка manual < correction < auto (use_count desc)
- `update_term_usage(config, phrase)`: обновляет `last_seen`/`use_count`, снимает `inactive`; планируется с потока инжекции на главный поток (`_apply_term_usage_on_main`); dirty-flag `_config_usage_dirty`
- `apply_decay(config, max_age_days)`: помечает устаревшие auto/correction термины inactive; manual — вечны
- `run_decay_if_due()` + `_decay_tick(@rumps.timer(3600))`: раз в 24 h
- `_apply_candidates_to_user_terms()`: вставляет dict-записи вместо строк (с source/added_at/last_seen)
- `_watch_prompt_file()`: при редактировании .txt сопоставляет строки с существующими dict-объектами (метаданные сохраняются); новые строки → `source="manual"`
- `_revert_for_lang()`: нормализует list[str] снэпшоты в dict при откате
- «Manage Terms…» в меню: статистика + «Удалить неактивные»
- **Файлы:** `src/utils.py`, `src/app.py`, `src/menu_bar.py`, `tests/test_decay.py` (12 тестов)

---

### ✅ Etap 11 — Correction-driven candidates from popup edits
- Добавлен `src/correction_analyzer.py`: инкрементально читает `~/.clicknspeak_dataset.jsonl`, строит `corrections.json` и извлекает `inserted_terms`/`replacement_pairs` через token-level diff (`ai_edited|raw_whisper` vs `user_final`)
- `corrections.json` пишется атомарно (tmp + `os.replace` + `fsync`), включает `last_processed_ts` и `processed_rows` для cheap incremental updates
- `_run_prompt_analysis()` в `app.py` теперь мерджит два источника кандидатов: correction + frequency; приоритет correction задаётся скором `correction_count * 10 + frequency_count`, поле `source` = `correction|frequency|both`
- `_maybe_trigger_prompt_analysis()` fast-path: сильный correction-сигнал в последних подтверждениях + рост `processed_rows` относительно `_last_fast_path_processed_rows` → анализ сразу; тот же `corrections_index` передаётся в `_run_prompt_analysis` — без повторного `update_corrections_index()`; порог `min_correction_count` для correction-кандидатов задаётся по скрипту (как у frequency), не фиксированная двойка
- Экспортированы публичные алиасы `TERM_STOPLIST`, `RUS_FUNCTION_WORDS`, `TERM_PATTERN` в `log_analyzer.py` для единых фильтров шума
- **Файлы:** `src/correction_analyzer.py`, `src/app.py`, `src/log_analyzer.py`, `src/utils.py`, `tests/test_correction_analyzer.py`, `AGENTS.md`

---

### ✅ Etap 12 — Language-agnostic analyzer thresholds (script buckets)
- Анализаторы используют script-based buckets **`latin`** / **`cyrillic`** (не путать с ISO-кодами); legacy `corrections.json` v1 (`en`/`ru`) мигрирует в v2 при загрузке
- Пороги частоты: `auto_prompt_check_min_count_primary` (default 10, primary script — stricter) vs `auto_prompt_check_min_count_additional` (default 5, additional script — more permissive), плюс `auto_prompt_lookback` 300, интервал проверки **20** фраз, on-demand lookback **1000**, cooldown **150**, cap **15** кандидатов на bucket при merge
- `_collect_english_terms`: опциональный bypass фильтра «≥2 сессий» для латинских токенов, если переданный `term_has_correction_signal(lower)` истинен (в `app.py` это совпадение с любым ключом в `inserted_terms` индекса corrections)
- `get_language_script()`, `target_lang_for_script_bucket()`, `existing_terms_union_for_script()`, `skipped_phrases_merge_for_script()` в `utils.py`
- **Файлы:** `src/correction_analyzer.py`, `src/log_analyzer.py`, `src/app.py`, `src/utils.py`, `tests/test_log_analyzer.py`, `tests/test_correction_analyzer.py`, `AGENTS.md`

---

### ✅ Etap 13 — Metrics UI, vocab for API editors, Add to Dictionary, threading fixes
- `src/metrics.py` + `metrics_history.jsonl`: `compute_metrics`, тренды, acceptance, prompt token budget; `append_metrics_history` / ротация; меню **Statistics…** (`get_metrics_snapshot(force=True)`), опциональное открытие файла истории; `scripts/print_metrics.py` — JSON в stdout для отладки
- `run_daily_maintenance_if_due()` — decay + фоновый `run_metrics_if_due`; деградация edit-score → редкое уведомление (`notify_on_metrics`, throttle 30 дней)
- `src/vocab_provider.py` — `collect_known_terms` / `collect_misrecognitions` / `add_term_to_user_terms`; `ExternalApiEditor` в `ai_editor.py` + расширенные system prompts для Gemini (realtime + file)
- Попап: `DictionaryAwareTextView`, тосты по строке заголовка; `_apply_candidates` для auto-терминов берёт `frequency_count` в `use_count`
- Главный поток: `update_term_usage` через очередь; сброс `_config_usage_dirty` каждые 60 s и перед рестартом транскрайбера; коммиты авто-анализа через `_main_thread_queue`; `write_text_atomic` для `.txt` терминов
- **Файлы:** `src/metrics.py`, `src/vocab_provider.py`, `src/ai_editor.py`, `src/app.py`, `src/menu_bar.py`, `src/preview_panel.py`, `src/suggestions_panel.py`, `src/utils.py`, `src/correction_analyzer.py`, `scripts/print_metrics.py`, тесты `test_metrics.py`, `test_vocab_provider.py`

---

### ✅ Etap 14 — Canonical term identity across analyzers/merge/metrics
- Добавлены `canonicalize_term()` и `canonical_term_key()` в `utils.py` для единой identity-модели термов
- Boundary punctuation схлопывается (`GitHub.` == `GitHub`), но внутренние символы терма сохраняются (`C++`, `C#`, `node.js`, `v2.1`, `foo_bar`, `x-y`)
- Сохранены семантически значимые leading-префиксы (`.NET`, `@mention`) при канонизации display-формы
- Ключи dedupe/merge/cooldown переведены на canonical-key в `app.py` и `menu_bar.py`; канонизация внедрена до агрегации в `log_analyzer.py` и `correction_analyzer.py`
- `vocab_provider.py` использует canonical-key для add/dedupe; `metrics.py` использует canonical-key на dictionary side для hit-rate
- Покрытие: `tests/test_term_normalization.py` + апдейты в `tests/test_log_analyzer.py`, `tests/test_correction_analyzer.py`, `tests/test_vocab_provider.py`, `tests/test_metrics.py`
