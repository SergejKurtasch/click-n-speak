"""Tests for audio settings refactor: new defaults, menu removal, short-phrase handling."""

import numpy as np
import pytest
from unittest.mock import patch, MagicMock, call

from src.recorder import AudioRecorder


# ---------------------------------------------------------------------------
# 1. New default values
# ---------------------------------------------------------------------------

def test_recorder_default_silence_duration():
    recorder = AudioRecorder(sample_rate=16000)
    assert recorder.silence_duration == 0.5


def test_recorder_default_min_speech_duration():
    recorder = AudioRecorder(sample_rate=16000)
    assert recorder.min_speech_duration == 0.5


def test_app_passes_new_defaults_to_recorder():
    """SVoiceRecApp must wire silence_duration=0.5 and min_speech_duration=0.5 to AudioRecorder."""
    from src.app import SVoiceRecApp

    captured = {}

    def fake_recorder(**kwargs):
        captured.update(kwargs)
        return MagicMock()

    # Pass a non-existent path so load_config falls back to empty defaults
    with patch("src.app.AudioRecorder", side_effect=fake_recorder), \
         patch("src.app.TranscriberProcessWrapper"), \
         patch("src.app.HotkeyHandler"), \
         patch("src.app.log_info"), \
         patch("src.app.log_error"):
        try:
            SVoiceRecApp("/tmp/nonexistent_config_abc123.json")
        except Exception:
            pass

    assert captured.get("silence_duration") == 0.5, (
        f"Expected silence_duration=0.5, got {captured.get('silence_duration')}"
    )
    assert captured.get("min_speech_duration") == 0.5, (
        f"Expected min_speech_duration=0.5, got {captured.get('min_speech_duration')}"
    )


def test_config_overrides_silence_duration(tmp_path):
    """A value in config.json must still override the default."""
    import json as _json
    from src.app import SVoiceRecApp

    config_file = tmp_path / "config.json"
    config_file.write_text(
        _json.dumps({"silence_duration": 1.5, "min_speech_duration": 0.8}),
        encoding="utf-8",
    )

    captured = {}

    def fake_recorder(**kwargs):
        captured.update(kwargs)
        return MagicMock()

    with patch("src.app.AudioRecorder", side_effect=fake_recorder), \
         patch("src.app.TranscriberProcessWrapper"), \
         patch("src.app.HotkeyHandler"), \
         patch("src.app.log_info"), \
         patch("src.app.log_error"):
        try:
            SVoiceRecApp(str(config_file))
        except Exception:
            pass

    assert captured.get("silence_duration") == 1.5
    assert captured.get("min_speech_duration") == 0.8


# ---------------------------------------------------------------------------
# 2. Short-phrase silence trigger threshold
# ---------------------------------------------------------------------------

def test_short_phrase_triggers_after_0_5s_silence():
    """With default silence_duration=0.5, a short phrase (<4s) must trigger after 0.5s of silence."""
    recorder = AudioRecorder(sample_rate=16000)
    recorder.recording = True
    recorder.has_speech_in_chunk = True

    fired = []
    recorder.chunk_callback = lambda audio: fired.append(len(audio))

    # Simulate state: 2s of speech already accumulated, then 0.5s of silence
    samples_2s = np.ones((32000, 1), dtype=np.float32)
    recorder.audio_data = [samples_2s]
    recorder.current_chunk_duration = 2.0
    recorder.silence_counter = 0.5  # exactly at threshold

    # Feed a tiny silent frame to trigger the check (RMS path, no VAD)
    frame = np.zeros((160, 1), dtype=np.float32)
    with patch("src.recorder.HAVE_VAD", False):
        recorder._callback(frame, 160, None, None)

    assert len(fired) == 1, "Chunk must fire once after 0.5s silence in short phrase"


def test_short_phrase_does_not_trigger_before_0_5s_silence():
    """Chunk must NOT fire if only 0.3s of silence has accumulated (below new threshold)."""
    recorder = AudioRecorder(sample_rate=16000)
    recorder.recording = True
    recorder.has_speech_in_chunk = True

    fired = []
    recorder.chunk_callback = lambda audio: fired.append(len(audio))

    samples_2s = np.ones((32000, 1), dtype=np.float32)
    recorder.audio_data = [samples_2s]
    recorder.current_chunk_duration = 2.0
    recorder.silence_counter = 0.3  # below 0.5s threshold

    frame = np.zeros((160, 1), dtype=np.float32)
    with patch("src.recorder.HAVE_VAD", False):
        recorder._callback(frame, 160, None, None)

    assert len(fired) == 0, "Chunk must NOT fire when silence < 0.5s"


def test_old_1s_default_would_not_have_fired():
    """Regression: verify 0.5s silence would NOT have triggered with old 1.0s default."""
    recorder = AudioRecorder(sample_rate=16000, silence_duration=1.0)
    recorder.recording = True
    recorder.has_speech_in_chunk = True

    fired = []
    recorder.chunk_callback = lambda audio: fired.append(len(audio))

    samples_2s = np.ones((32000, 1), dtype=np.float32)
    recorder.audio_data = [samples_2s]
    recorder.current_chunk_duration = 2.0
    recorder.silence_counter = 0.5  # same state, but old 1.0s threshold

    frame = np.zeros((160, 1), dtype=np.float32)
    with patch("src.recorder.HAVE_VAD", False):
        recorder._callback(frame, 160, None, None)

    assert len(fired) == 0, "0.5s silence with old 1.0s threshold must NOT fire"


# ---------------------------------------------------------------------------
# 3. min_speech_duration filtering — updated for new default (0.5)
# ---------------------------------------------------------------------------

def test_min_speech_duration_filters_noise_chunk():
    """Chunks with less than min_speech_duration (0.5s default) must be discarded."""
    recorder = AudioRecorder(sample_rate=16000)
    recorder.recording = True

    fired = []
    recorder.chunk_callback = lambda audio: fired.append(len(audio))

    # 0.2s of audio — below 0.5s threshold
    tiny = np.ones((3200, 1), dtype=np.float32)
    recorder.audio_data = [tiny]
    recorder.has_speech_in_chunk = True
    recorder.current_chunk_duration = 0.2
    recorder.silence_counter = 0.5  # at threshold, would otherwise fire

    frame = np.zeros((160, 1), dtype=np.float32)
    with patch("src.recorder.HAVE_VAD", False):
        recorder._callback(frame, 160, None, None)

    assert len(fired) == 0, "Noise chunk shorter than min_speech_duration must be discarded"


def test_min_speech_duration_passes_valid_chunk():
    """Chunks with more than min_speech_duration (0.5s default) must pass through."""
    recorder = AudioRecorder(sample_rate=16000)
    recorder.recording = True

    fired = []
    recorder.chunk_callback = lambda audio: fired.append(len(audio))

    # 1.5s of speech, 0.5s of silence → speech_duration = 1.0s > 0.5s threshold
    samples = np.ones((24000, 1), dtype=np.float32)
    recorder.audio_data = [samples]
    recorder.has_speech_in_chunk = True
    recorder.current_chunk_duration = 2.0
    recorder.silence_counter = 0.5

    frame = np.zeros((160, 1), dtype=np.float32)
    with patch("src.recorder.HAVE_VAD", False):
        recorder._callback(frame, 160, None, None)

    assert len(fired) == 1, "Valid chunk above min_speech_duration must fire"


def test_stop_discards_chunk_below_min_speech_duration():
    """recorder.stop() must return None when accumulated audio is below min_speech_duration."""
    recorder = AudioRecorder(sample_rate=16000, min_speech_duration=0.5)
    recorder.recording = True
    # 0.2s — below 0.5s threshold
    tiny = np.ones((3200, 1), dtype=np.float32)
    recorder.audio_data = [tiny]
    recorder.has_speech_in_chunk = True

    with patch.object(recorder, "_stop_stream_with_timeout"):
        result = recorder.stop()

    assert result is None, "stop() must return None for chunk below min_speech_duration"


def test_stop_returns_chunk_above_min_speech_duration():
    """recorder.stop() must return audio when accumulated audio is above min_speech_duration."""
    recorder = AudioRecorder(sample_rate=16000, min_speech_duration=0.5)
    recorder.recording = True
    # 1s — above 0.5s threshold
    valid = np.ones((16000, 1), dtype=np.float32)
    recorder.audio_data = [valid]
    recorder.has_speech_in_chunk = True

    with patch.object(recorder, "_stop_stream_with_timeout"):
        result = recorder.stop()

    assert result is not None, "stop() must return audio for valid chunk"
    assert len(result) > 0


# ---------------------------------------------------------------------------
# 4. Menu does not contain removed items
# ---------------------------------------------------------------------------

def test_silence_delay_not_in_menu():
    """'Silence Delay' and 'Min Speech Duration' must not appear in menu_bar.py."""
    from pathlib import Path
    source = (Path(__file__).parent.parent / "src" / "menu_bar.py").read_text(encoding="utf-8")
    assert "Silence Delay" not in source, "'Silence Delay' must be removed from menu_bar.py"
    assert "Min Speech Duration" not in source, "'Min Speech Duration' must be removed from menu_bar.py"


def test_set_sensitivity_method_removed():
    """set_sensitivity callback must no longer exist on ClickNSpeakApp."""
    from src.menu_bar import ClickNSpeakApp
    assert not hasattr(ClickNSpeakApp, "set_sensitivity"), (
        "set_sensitivity method must be removed after Silence Delay menu removal"
    )


def test_set_min_speech_duration_method_removed():
    """set_min_speech_duration callback must no longer exist on ClickNSpeakApp."""
    from src.menu_bar import ClickNSpeakApp
    assert not hasattr(ClickNSpeakApp, "set_min_speech_duration"), (
        "set_min_speech_duration method must be removed after Min Speech Duration menu removal"
    )
