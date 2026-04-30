"""
tests/test_chunk_drain_on_stop.py

Verifies that chunk_worker processes ALL queued non-final chunks after stop
instead of dropping them (fix for lost speech bug: up to 17s of audio was
silently discarded when the worker was behind the recorder).
"""

import queue
import threading
import time
from unittest.mock import MagicMock, patch, call

import numpy as np
import pytest


def _make_app():
    """Instantiate a minimal SVoiceRecApp without any native dependencies."""
    from src.app import SVoiceRecApp

    with patch("src.app.AudioRecorder"), \
         patch("src.app.TranscriberProcessWrapper"), \
         patch("src.app.HotkeyHandler"), \
         patch("src.app.send_notification"), \
         patch("src.app.get_ui_strings", return_value={
             "transcribing_title": "Распознаю...",
             "transcribing_body": "",
             "still_working_title": "Всё ещё...",
             "still_working_body": "",
             "ready_title": "",
             "ready_body": "",
             "edit_confirm_title": "Подтверди",
             "transcription_instruction": "",
         }), \
         patch("src.app.get_primary_language", return_value="ru"), \
         patch("src.app.build_initial_prompt", return_value=""), \
         patch("src.app.log_info"), \
         patch("src.app.log_error"), \
         patch("src.app.log_exception"):

        app = SVoiceRecApp.__new__(SVoiceRecApp)
        app.config = {}
        app.is_recording = False
        app.is_processing = False
        app.transcribed_parts = []
        app._raw_whisper_chunks = []
        app._session_id = 1
        app.chunk_queue = queue.Queue()
        app.stop_worker = threading.Event()
        app.recorder = MagicMock()
        app.transcriber = MagicMock()
        app.menu_bar = None
        app._main_thread_queue = queue.Queue()
        app._transcription_cycle_id = 0
        app._delayed_transcribing_timer = None
        app._timer_lock = threading.Lock()
        app._preview_panel = MagicMock()
        app._still_working_delay_seconds = 999
        app._cached_initial_prompt = ""
        app._initial_prompt_dirty = False
        app._last_transcription_time = time.time()
        app.ai_editor = None
        app.worker_thread = None
        return app


def test_non_final_chunks_processed_after_stop():
    """All queued non-final chunks must be transcribed even after stop_worker is set."""
    app = _make_app()

    # Transcriber returns distinct text per call so we can count them.
    texts = ["часть один", "часть два", "часть три", "финал"]
    app.transcriber.transcribe.side_effect = texts

    audio = np.zeros(16000, dtype=np.float32)

    # Enqueue 3 non-final chunks and 1 final
    for _ in range(3):
        app.chunk_queue.put_nowait((audio, False))
    app.chunk_queue.put_nowait((audio, True))

    # Signal stop BEFORE the worker runs (simulates the race condition)
    app.stop_worker.set()

    # Run chunk_worker in its own thread (mirrors production usage)
    t = threading.Thread(target=app.chunk_worker)
    t.start()
    t.join(timeout=5.0)
    assert not t.is_alive(), "chunk_worker did not finish within timeout"

    # All 4 chunks must have been transcribed
    assert app.transcriber.transcribe.call_count == 4, (
        f"Expected 4 transcribe calls, got {app.transcriber.transcribe.call_count}. "
        "Non-final chunks were likely dropped on stop."
    )
    # All 4 texts must appear in transcribed_parts
    assert app.transcribed_parts == texts, (
        f"transcribed_parts={app.transcribed_parts!r} — some chunks missing."
    )


def test_process_chunk_no_longer_skips_non_final_on_stop():
    """process_chunk must not early-return for non-final chunks when stop_worker is set."""
    app = _make_app()
    app.transcriber.transcribe.return_value = "слово"

    audio = np.zeros(16000, dtype=np.float32)
    app.stop_worker.set()  # stop already requested

    with patch("src.app.log_info"):
        app.process_chunk(audio, is_final_chunk=False, session_id=1)

    # transcriber.transcribe must have been called despite stop_worker being set
    app.transcriber.transcribe.assert_called_once()
    assert "слово" in app.transcribed_parts
