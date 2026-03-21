import queue
import threading
from unittest.mock import MagicMock, patch

import pytest

from src.app import SVoiceRecApp

@patch("src.app.AudioRecorder")
@patch("src.app.WhisperTranscriber")
def test_app_chunk_chronological_order(mock_transcriber_cls, mock_recorder_cls):
    """
    Ensures that when the recording stops, the chunks already in the queue are processed
    BEFORE the final audio chunk, fixing the chronological order bug.
    """
    app = SVoiceRecApp(config_path="dummy.json")
    
    # Mock transcriber to just return a string version of the audio chunk "data"
    app.transcriber.transcribe = MagicMock(side_effect=lambda audio, **kwargs: audio.decode() if isinstance(audio, bytes) else str(audio))
    
    # Mock injector to just capture the injected text
    injected_texts = []
    
    with patch("src.app.inject_text", new=lambda text: injected_texts.append(text)):
        # Simulate recording state
        app.is_recording = True
        app.transcribed_parts = []
        app.stop_worker.clear()
        
        # Start chunk worker
        app.worker_thread = threading.Thread(target=app.chunk_worker)
        app.worker_thread.start()
        
        # Add normal chunks to queue (what happens during live recording)
        app.on_chunk_received(b"chunk1")
        app.on_chunk_received(b"chunk2")
        
        # Simulate stop_recording_and_process grabbing the final chunk
        # It should put it at the end of the queue
        app.chunk_queue.put((b"final_chunk", True))
        app.stop_worker.set()
        
        # Wait for worker to finish
        app.worker_thread.join(timeout=5)
        
        # Validate order: prior to fix, final_chunk would be first
        assert injected_texts == ["chunk1 ", "chunk2 ", "final_chunk "]
