import numpy as np
import pytest
from unittest.mock import patch, MagicMock

import mlx_whisper  # needed for mocking or ensuring it's not actually called
from src.transcriber import WhisperTranscriber, _has_consecutive_word_repetition

def test_has_consecutive_word_repetition():
    assert _has_consecutive_word_repetition("hello hello", 2) == True
    assert _has_consecutive_word_repetition("hello world hello", 2) == False
    assert _has_consecutive_word_repetition("test test test", 2) == True

@patch("src.transcriber._call_mlx_transcribe")
def test_transcribe_hallucination_filtered(mock_call):
    # Mock returning a hallucination phrase
    mock_call.return_value = {"text": "subtitles by amara.org", "language": "en"}
    
    with patch("src.transcriber.log_info"):  # suppress logging
        transcriber = WhisperTranscriber(model_name="dummy")
        audio = np.zeros(16000, dtype=np.float32)
        
        # The chunk should be dropped (returns "")
        result = transcriber.transcribe(audio, is_final_chunk=False)
        assert result == ""

@patch("src.transcriber._call_mlx_transcribe")
def test_transcribe_normal_word_not_filtered(mock_call):
    # 'insert' was removed from hallucination phrases, so it should NOT be filtered
    mock_call.return_value = {"text": "I need to insert a coin", "language": "en"}
    
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        audio = np.zeros(16000, dtype=np.float32)
        
        result = transcriber.transcribe(audio, allowed_languages=["en"], is_final_chunk=False)
        assert result == "I need to insert a coin"

@patch("src.transcriber._call_mlx_transcribe")
def test_transcribe_language_retry_padding(mock_call):
    # First call returns wrong language "cs"
    # Second call returns correct language "ru"
    mock_call.side_effect = [
        {"text": "Dobrý den", "language": "cs"},
        {"text": "Добрый день", "language": "ru"}
    ]
    
    with patch("src.transcriber.log_info"):
        transcriber = WhisperTranscriber(model_name="dummy")
        audio = np.zeros(16000, dtype=np.float32)
        
        result = transcriber.transcribe(audio, allowed_languages=["ru"], is_final_chunk=False)
        
        assert result == "Добрый день"
        assert mock_call.call_count == 2
        
        # Verify the second call had padded audio (length 16000 + 1600 + 1600 = 19200)
        args, kwargs = mock_call.call_args_list[1]
        assert len(args[0]) == 19200
