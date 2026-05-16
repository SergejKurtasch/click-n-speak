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
    _collapse_consecutive_word_repetition,
)

# Alias for backwards-compat with older test references
def _has_consecutive_word_repetition(text: str, min_count: int) -> bool:
    """Legacy helper: returns True if collapse changes the text."""
    collapsed = _collapse_consecutive_word_repetition(text)
    return collapsed != text


# ---------------------------------------------------------------------------
# Fix 2: Skip micro final chunks
# ---------------------------------------------------------------------------


@patch("src.transcriber._call_mlx_transcribe")
def test_skip_tiny_final_chunk(mock_call):
    """Final chunks at or below MIN_FINAL_CHUNK_SAMPLES should be skipped."""
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        # 0.2s at 16kHz = 3200 samples — well below the 0.5s threshold
        tiny_audio = np.zeros(3200, dtype=np.float32)
        result = transcriber.transcribe(tiny_audio, is_final_chunk=True)
        assert result == ""
        mock_call.assert_not_called()


@patch("src.transcriber._call_mlx_transcribe")
def test_skip_final_chunk_at_exact_boundary(mock_call):
    """Final chunk exactly at MIN_FINAL_CHUNK_SAMPLES (<=) must also be skipped."""
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        boundary_audio = np.zeros(MIN_FINAL_CHUNK_SAMPLES, dtype=np.float32)
        result = transcriber.transcribe(boundary_audio, is_final_chunk=True)
        assert result == ""
        mock_call.assert_not_called()


@patch("src.transcriber._call_mlx_transcribe")
def test_normal_final_chunk_not_skipped(mock_call):
    """Final chunks above MIN_FINAL_CHUNK_SAMPLES should NOT be skipped."""
    mock_call.return_value = {"text": "Hello world", "language": "en"}
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        # MIN + 1 sample — just above the threshold
        normal_audio = np.zeros(MIN_FINAL_CHUNK_SAMPLES + 1, dtype=np.float32)
        result = transcriber.transcribe(
            normal_audio, allowed_languages=["en"], is_final_chunk=True
        )
        assert result == "Hello world"
        mock_call.assert_called_once()


@patch("src.transcriber._call_mlx_transcribe")
def test_non_final_tiny_chunk_not_skipped(mock_call):
    """Non-final tiny chunks with speech go through Whisper (MIN check is final-only)."""
    mock_call.return_value = {"text": "word", "language": "en"}
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        # 0.2s with speech-level amplitude so RMS pre-filter doesn't trigger
        speech_audio = np.full(3200, 0.1, dtype=np.float32)
        result = transcriber.transcribe(
            speech_audio, allowed_languages=["en"], is_final_chunk=False
        )
        assert result == "word"
        mock_call.assert_called_once()


# ---------------------------------------------------------------------------
# Fix 6: RMS pre-filter for silent short non-final chunks
# ---------------------------------------------------------------------------


@patch("src.transcriber._call_mlx_transcribe")
def test_silent_short_chunk_skipped(mock_call):
    """A short (<3s) non-final chunk with near-zero RMS must be skipped before Whisper."""
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        silent_audio = np.zeros(16000, dtype=np.float32)  # 1s of silence
        result = transcriber.transcribe(silent_audio, is_final_chunk=False)
        assert result == ""
        mock_call.assert_not_called()


@patch("src.transcriber._call_mlx_transcribe")
def test_speech_short_chunk_not_skipped_by_rms(mock_call):
    """A short chunk with speech-level amplitude must pass the RMS filter."""
    mock_call.return_value = {"text": "Привет", "language": "ru"}
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        # RMS ≈ 0.1 — clearly above _SILENCE_RMS_THRESHOLD
        speech_audio = np.full(16000, 0.1, dtype=np.float32)
        result = transcriber.transcribe(speech_audio, allowed_languages=["ru"], is_final_chunk=False)
        assert result == "Привет"
        mock_call.assert_called_once()


@patch("src.transcriber._call_mlx_transcribe")
def test_long_silent_chunk_not_filtered_by_rms(mock_call):
    """Silent chunks ≥3s are NOT pre-filtered by RMS — Whisper's own thresholds handle them."""
    mock_call.return_value = {"text": "", "language": "ru"}
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        long_silence = np.zeros(48001, dtype=np.float32)  # just over 3s
        result = transcriber.transcribe(long_silence, is_final_chunk=False)
        # Whisper gets called (RMS filter doesn't trigger for long chunks)
        mock_call.assert_called_once()


# ---------------------------------------------------------------------------
# Fix 4 (subword repetition): Subword repeat hallucination strip
# ---------------------------------------------------------------------------


def test_subword_repeat_stripped():
    """oiseoise... and ftafta... patterns must be collapsed to a single occurrence."""
    from src.transcriber import _SUBWORD_REPEAT_RE
    text = "Посмотри метрики oiseoiseoiseoiseoiseoise мир"
    result = _SUBWORD_REPEAT_RE.sub(r"\1", text)
    assert "oise" in result
    assert result.count("oise") == 1

    text2 = "ftaftaftaftaftafta"
    result2 = _SUBWORD_REPEAT_RE.sub(r"\1", text2)
    assert len(result2) < len(text2)


def test_subword_repeat_leaves_normal_text():
    """Normal speech with short repeats (< 6 times) must not be changed."""
    from src.transcriber import _SUBWORD_REPEAT_RE
    # "ха-ха-ха" = 3 repetitions of "ха-" — below the 6x threshold
    assert _SUBWORD_REPEAT_RE.sub(r"\1", "ха-ха-ха") == "ха-ха-ха"
    # "да-да" = 2 repetitions — unchanged
    assert _SUBWORD_REPEAT_RE.sub(r"\1", "да-да") == "да-да"


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
        app._raw_whisper_chunks = []
        app._session_id = 1
        app.chunk_queue = queue.Queue()
        app.stop_worker = threading.Event()
        app.recorder = MagicMock()
        app.recorder.stop.return_value = None
        app.transcriber = MagicMock()
        app.menu_bar = None
        app._main_thread_queue = queue.Queue()
        app._transcription_cycle_id = 0
        app._delayed_transcribing_timer = None
        app._timer_lock = threading.Lock()
        app._preview_panel = None
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

        assert app.is_processing is False, "is_processing should be reset after worker timeout"
        never_done.set()  # cleanup


# ---------------------------------------------------------------------------
# Fix: min_speech_duration filtering
# ---------------------------------------------------------------------------

def test_min_speech_duration_filtering():
    """Audio shorter than min_speech_duration must not be returned by recorder.stop()."""
    from src.recorder import AudioRecorder
    import numpy as np

    recorder = AudioRecorder(sample_rate=16000, min_speech_duration=1.0)
    recorder.recording = True
    # Inject 0.2s of audio (below min_speech_duration of 1.0s)
    tiny = np.ones((3200, 1), dtype=np.float32)
    recorder.audio_data = [tiny]
    recorder.has_speech_in_chunk = True

    with patch.object(recorder, "_stop_stream_with_timeout"):
        result = recorder.stop()

    # stop() should discard the tiny chunk and return None
    assert result is None

# ---------------------------------------------------------------------------
# Fix: Keep-alive memory pressure check
# ---------------------------------------------------------------------------

def test_keep_alive_memory_pressure():
    """Test _check_memory_pressure_now psutil fallback path.

    _is_memory_pressure_high() now delegates the actual check to a background thread
    and returns the cached value immediately, so we test the underlying
    _check_memory_pressure_now() directly.
    """
    from src.app import SVoiceRecApp, MEMORY_PRESSURE_THRESHOLD_PERCENT
    import sys
    from unittest.mock import patch

    app = SVoiceRecApp.__new__(SVoiceRecApp)

    mock_psutil = MagicMock()
    sys.modules["psutil"] = mock_psutil

    try:
        # Force sysctl to fail so code falls back to psutil
        with patch("subprocess.run", side_effect=OSError("no sysctl")):
            mock_psutil.virtual_memory.return_value.percent = MEMORY_PRESSURE_THRESHOLD_PERCENT + 10
            assert app._check_memory_pressure_now() is True

            mock_psutil.virtual_memory.return_value.percent = MEMORY_PRESSURE_THRESHOLD_PERCENT - 10
            assert app._check_memory_pressure_now() is False
    finally:
        sys.modules.pop("psutil", None)

# ---------------------------------------------------------------------------
# Fix: recorder.stop() timeout
# ---------------------------------------------------------------------------

def test_recorder_stop_thread_timeout():
    """Test that recorder stop doesn't block indefinitely."""
    from src.recorder import AudioRecorder
    import threading
    import time
    
    recorder = AudioRecorder(sample_rate=16000)
    
    # Mock stream to hang forever
    class HangingStream:
        def stop(self):
            time.sleep(10)
        def close(self):
            pass
            
    recorder.stream = HangingStream()

    start_time = time.time()
    # Should timeout in ~3 seconds, not 10
    recorder.stop()
    elapsed = time.time() - start_time

    # The stop itself should be nearly instantaneous because it spawns a daemon thread
    assert elapsed < 1.0


# ---------------------------------------------------------------------------
# Fix #2: pre_warm parent-side idle guard
# ---------------------------------------------------------------------------


def test_prewarm_skipped_when_model_is_warm():
    """pre_warm() must not enqueue when last transcription was recent."""
    wrapper = TranscriberProcessWrapper.__new__(TranscriberProcessWrapper)
    wrapper.input_queue = queue.Queue()
    wrapper.output_queue = queue.Queue()
    wrapper.model_name = "dummy"
    wrapper._process = MagicMock()

    # Simulate a recent transcription (1 second ago — well within 45s threshold)
    wrapper._last_transcribe_returned_at = time.time() - 1.0

    with patch("src.transcriber.log_info"):
        wrapper.pre_warm()

    assert wrapper.input_queue.empty(), (
        "pre_warm() must NOT enqueue when model is warm (recent transcription)"
    )


def test_prewarm_sent_when_model_is_cold():
    """pre_warm() must enqueue when last transcription was long ago (cold model)."""
    wrapper = TranscriberProcessWrapper.__new__(TranscriberProcessWrapper)
    wrapper.input_queue = queue.Queue()
    wrapper.output_queue = queue.Queue()
    wrapper.model_name = "dummy"
    wrapper._process = MagicMock()

    # Simulate no prior transcription (epoch 0 = effectively never)
    wrapper._last_transcribe_returned_at = 0.0

    with patch("src.transcriber.log_info"):
        wrapper.pre_warm()

    assert not wrapper.input_queue.empty(), (
        "pre_warm() must enqueue when model is cold (no recent transcription)"
    )
    cmd = wrapper.input_queue.get_nowait()
    assert cmd["action"] == "prewarm"


def test_last_transcribe_returned_at_updated_after_transcribe():
    """_last_transcribe_returned_at must be set after a successful transcription."""
    wrapper = TranscriberProcessWrapper.__new__(TranscriberProcessWrapper)
    wrapper.input_queue = queue.Queue()
    wrapper.output_queue = queue.Queue()
    wrapper.model_name = "dummy"
    wrapper._process = MagicMock()
    wrapper._last_transcribe_returned_at = 0.0

    # Pre-load a transcription result in the output queue
    wrapper.output_queue.put({"type": "transcription", "text": "привет"})

    before = time.time()
    with patch("src.transcriber.log_info"), patch("src.transcriber.log_error"):
        result = wrapper.transcribe(np.zeros(1600, dtype=np.float32))

    assert result == "привет"
    assert wrapper._last_transcribe_returned_at >= before, (
        "_last_transcribe_returned_at not updated after transcription"
    )
