"""Tests for stability fixes: transcriber timeout, micro-chunk skip, hallucination filter, is_processing reset."""

import time
import queue
import threading
import numpy as np
import pytest
from unittest.mock import patch, MagicMock, PropertyMock

from src.transcriber import (
    WhisperTranscriber,
    TranscriberProcessWrapper,
    MIN_FINAL_CHUNK_SAMPLES,
    TRANSCRIBER_TIMEOUT_SECONDS,
    _has_consecutive_word_repetition,
)


# ---------------------------------------------------------------------------
# Fix 2: Skip micro final chunks
# ---------------------------------------------------------------------------


@patch("src.transcriber._call_mlx_transcribe")
def test_skip_tiny_final_chunk(mock_call):
    """Final chunks shorter than MIN_FINAL_CHUNK_SAMPLES should be skipped."""
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        # 0.2s at 16kHz = 3200 samples — below the threshold
        tiny_audio = np.zeros(3200, dtype=np.float32)
        result = transcriber.transcribe(tiny_audio, is_final_chunk=True)
        assert result == ""
        # mlx_whisper should NOT have been called
        mock_call.assert_not_called()


@patch("src.transcriber._call_mlx_transcribe")
def test_normal_final_chunk_not_skipped(mock_call):
    """Final chunks above MIN_FINAL_CHUNK_SAMPLES should NOT be skipped."""
    mock_call.return_value = {"text": "Hello world", "language": "en"}
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        # 1s at 16kHz = 16000 samples — above the threshold
        normal_audio = np.zeros(16000, dtype=np.float32)
        result = transcriber.transcribe(
            normal_audio, allowed_languages=["en"], is_final_chunk=True
        )
        assert result == "Hello world"
        mock_call.assert_called_once()


@patch("src.transcriber._call_mlx_transcribe")
def test_non_final_tiny_chunk_not_skipped(mock_call):
    """Non-final tiny chunks should still be processed (the skip only applies to final chunks)."""
    mock_call.return_value = {"text": "word", "language": "en"}
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        tiny_audio = np.zeros(3200, dtype=np.float32)
        result = transcriber.transcribe(
            tiny_audio, allowed_languages=["en"], is_final_chunk=False
        )
        # Not skipped because is_final_chunk=False
        assert result == "word"
        mock_call.assert_called_once()


# ---------------------------------------------------------------------------
# Fix 3: Expanded hallucination filter
# ---------------------------------------------------------------------------


@patch("src.transcriber._call_mlx_transcribe")
def test_hallucination_subtitles_ru_filtered(mock_call):
    """'Субтитры создавал DimaTorzok' should be filtered out."""
    mock_call.return_value = {
        "text": "Субтитры создавал DimaTorzok",
        "language": "ru",
    }
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        audio = np.zeros(16000, dtype=np.float32)
        result = transcriber.transcribe(audio, is_final_chunk=False)
        assert result == ""


@patch("src.transcriber._call_mlx_transcribe")
def test_hallucination_generic_subtitry_filtered(mock_call):
    """Any text containing 'субтитры' should be filtered out."""
    mock_call.return_value = {
        "text": "Эти субтитры были сгенерированы автоматически",
        "language": "ru",
    }
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        audio = np.zeros(16000, dtype=np.float32)
        result = transcriber.transcribe(audio, is_final_chunk=False)
        assert result == ""


# ---------------------------------------------------------------------------
# Fix 1: Transcriber timeout (unit test with mock queues)
# ---------------------------------------------------------------------------


def test_transcriber_timeout_returns_empty():
    """TranscriberProcessWrapper.transcribe() should return '' after timeout if process hangs."""
    wrapper = TranscriberProcessWrapper.__new__(TranscriberProcessWrapper)
    wrapper.input_queue = queue.Queue()
    wrapper.output_queue = queue.Queue()
    wrapper.model_name = "dummy"
    wrapper._process = MagicMock()

    # Mock _restart_process so it doesn't actually fork
    wrapper._restart_process = MagicMock()

    # Monkey-patch the timeout to 1 second for fast testing
    import src.transcriber as mod
    original_timeout = mod.TRANSCRIBER_TIMEOUT_SECONDS
    mod.TRANSCRIBER_TIMEOUT_SECONDS = 1
    try:
        start = time.time()
        with patch("src.transcriber.log_error"):
            result = wrapper.transcribe(np.zeros(1600, dtype=np.float32))
        elapsed = time.time() - start
        assert result == ""
        assert elapsed < 3.0, f"Should timeout in ~1s, took {elapsed:.1f}s"
        wrapper._restart_process.assert_called_once()
    finally:
        mod.TRANSCRIBER_TIMEOUT_SECONDS = original_timeout


# ---------------------------------------------------------------------------
# Fix 4: is_processing reset on worker timeout
# ---------------------------------------------------------------------------


def test_is_processing_reset_on_worker_timeout():
    """is_processing must be False after worker_thread.join() times out."""
    from src.app import SVoiceRecApp

    with patch("src.app.AudioRecorder"), \
         patch("src.app.TranscriberProcessWrapper"), \
         patch("src.app.HotkeyHandler"), \
         patch("src.app.send_notification"), \
         patch("src.app.get_ui_strings", return_value={
             "transcribing_title": "", "transcribing_body": "",
             "still_working_title": "", "still_working_body": "",
             "ready_title": "", "ready_body": "",
         }), \
         patch("src.app.get_primary_language", return_value="ru"), \
         patch("src.app.log_info"), \
         patch("src.app.log_error"), \
         patch("src.app.log_exception"):
        app = SVoiceRecApp.__new__(SVoiceRecApp)
        app.config = {}
        app.is_recording = False
        app.is_processing = True
        app.transcribed_parts = []
        app.chunk_queue = queue.Queue()
        app.stop_worker = threading.Event()
        app.recorder = MagicMock()
        app.recorder.stop.return_value = None
        app.transcriber = MagicMock()
        app.menu_bar = None
        app._main_thread_queue = queue.Queue()
        app._transcription_cycle_id = 0
        app._delayed_transcribing_timer = None
        app._still_working_delay_seconds = 999  # don't fire during test

        # Create a worker thread that never finishes
        never_done = threading.Event()
        app.worker_thread = threading.Thread(target=never_done.wait, daemon=True)
        app.worker_thread.start()

        # Monkey-patch join timeout for fast test
        original_join = threading.Thread.join
        def fast_join(self, timeout=None):
            original_join(self, timeout=0.1)
        with patch.object(threading.Thread, 'join', fast_join):
            app.stop_recording_and_process()

        # is_processing must be reset even though worker didn't finish
        assert app.is_processing is False, "is_processing should be reset after worker timeout"
        never_done.set()  # cleanup
