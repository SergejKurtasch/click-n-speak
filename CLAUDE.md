# Click-n-speak — Project Map for Claude

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

AI Editor thread (per refinement call)
  └─ AiEditor.refine() spawns daemon thread with 15s timeout
  └─ Uses same MLX GPU as Whisper — protected by non-blocking lock
```

---

## Module map

| File | Responsibility | Key classes/functions |
|---|---|---|
| `main.py` | Entry point, wires everything up | `main()` |
| `src/app.py` | Core state machine, orchestrates all modules | `SVoiceRecApp` |
| `src/recorder.py` | Audio capture + VAD-based chunking | `AudioRecorder` |
| `src/transcriber.py` | Whisper via MLX in child process | `TranscriberProcessWrapper`, `WhisperTranscriber` |
| `src/ai_editor.py` | LLM post-processing (Qwen 1.5B 4-bit) | `AiEditor` |
| `src/preview_panel.py` | HUD popup (NSPanel) — non-interactive + interactive modes | `TranscriptionPreviewPanel` |
| `src/menu_bar.py` | rumps menu bar, UI timers, settings | `ClickNSpeakApp` |
| `src/hotkey_handler.py` | pynput global hotkey listener | `HotkeyHandler`, `CompatGlobalHotKeys` |
| `src/injector.py` | Types text into active app via pynput | `inject_text()` |
| `src/utils.py` | Logging, config paths, notifications, UI strings | `setup_logging()`, `get_config_path()` |
| `src/phrase_history.py` | Append-only phrase log (TSV) | `append_phrase()`, `get_last_phrases()` |
| `src/dataset_logger.py` | JSONL dataset for fine-tuning | `append_to_dataset()` |
| `src/log_analyzer.py` | Extracts frequent terms from phrase history | `generate_terms_hint_from_history()` |
| `src/updater.py` | GitHub releases update check | `check_for_update()` |

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
POPUP OPEN (interactive NSPanel)
  │  user edits text, presses Enter
  │  _on_confirm → _run_injection thread → restores focus → inject_text
  │  OR user presses Escape → _on_cancel
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

---

## Critical thread-safety rules

- **All NSPanel/UI calls must go through `_submit_for_main_thread()`** which puts them in `_main_thread_queue`, drained on main thread by rumps 0.3s timer.
- `chunk_worker` and `process_chunk` run on the worker thread — they only touch `self.transcribed_parts`, `self._session_id`, and queue jobs to main thread.
- `transcriber.transcribe()` is a **blocking call** — it waits for the child process to respond. The child process is single-threaded and serializes all requests.
- `AiEditor.refine()` uses a non-blocking lock — if a previous LLM call is still running, refinement is skipped entirely (Metal GPU conflict avoidance).

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
    → child process: WhisperTranscriber.transcribe()
      → mlx_whisper.transcribe()
      → hallucination filter (phrase list, word repetition, CJK chars)
      → language filter (retry with silence padding if wrong language)
  → text returned to chunk_worker
  → [if final + ai_editor_enabled] AiEditor.refine()  [15s timeout]
  → accumulated in self.transcribed_parts
  → [if not final] preview_panel.update_text()
  → [if final] preview_panel.show_interactive()
```

---

## GPU warmup strategy

| Trigger | Method | Effect |
|---|---|---|
| App startup | `start_model_warmup()` → `transcriber.warmup()` | One-time silence transcription in child process |
| Every 15 min idle | `_keep_alive_tick()` → `transcriber.warmup()` | **Currently a no-op** — `WhisperTranscriber._warmup_done=True` after first call |
| macOS wake from sleep | `start_wake_observer()` | Triggers `_do_keep_alive_warmup()` |
| **Each hotkey press** | `start_recording()` → `transcriber.pre_warm()` | **New**: real silence transcription bypassing `_warmup_done` guard |

---

## Config (`config.json`)

Key fields:
```json
{
  "primary_language": "ru",
  "additional_languages": ["en"],
  "initial_prompt": "...",
  "custom_prompts": {"ru": "...", "en": "..."},
  "ai_editor_enabled": true,
  "ai_editor_model": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
  "model_name": "mlx-community/whisper-large-v3-turbo",
  "silence_duration": 1.0,
  "target_speech_duration": 4.0,
  "max_speech_duration": 8.0,
  "min_speech_duration": 1.0
}
```

---

## UI flow — main-thread queue

All NSPanel calls are posted as `(fn, args, kwargs)` tuples to `_main_thread_queue`. Drained every 0.3s by `_drain_main_thread_queue` in `menu_bar.py`. Never call AppKit directly from worker threads.

---

## File paths (runtime)

| Resource | Dev path | .app path |
|---|---|---|
| `config.json` | `~/Click-n-speak/config.json` | `~/Library/Application Support/Click-n-speak/config.json` |
| `phrase_history.txt` | `~/Click-n-speak/phrase_history.txt` | `~/Library/Application Support/Click-n-speak/phrase_history.txt` |
| Log file | `~/Library/Logs/Click-n-speak.log` | same |
| Dataset | `~/.clicknspeak_dataset.jsonl` | same |

---

## Known latency profile

| Step | Typical | Worst case | Notes |
|---|---|---|---|
| First chunk collected | ~4-5s | ~8s | Depends on pauses in speech |
| Whisper transcription (warm) | 2-4s | 6s | Per chunk |
| Whisper transcription (cold GPU) | 15-21s | 25s | After long idle; `prewarm` on hotkey mitigates |
| AI Editor (Qwen 1.5B 4-bit) | 0.7-0.9s | 15s | Final chunk only; has timeout fallback |
| Popup appears after stop | ~3-6s | ~10s | = last chunk transcription + AI editor |
