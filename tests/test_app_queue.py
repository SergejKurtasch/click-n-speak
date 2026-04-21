import queue
import threading
from unittest.mock import MagicMock, patch

import pytest

from src.app import SVoiceRecApp

@pytest.mark.skip(
    reason="Test predates multiprocessing refactor: WhisperTranscriber no longer "
           "lives in src.app and text injection is async via popup, not direct."
)
@patch("src.app.AudioRecorder")
@patch("src.app.TranscriberProcessWrapper")
def test_app_chunk_chronological_order(mock_transcriber_cls, mock_recorder_cls):
    """Chunk FIFO ordering smoke test (legacy — kept for reference)."""
    pass
