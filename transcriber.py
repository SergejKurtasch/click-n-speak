import mlx_whisper
import os
import time
import numpy as np

class WhisperTranscriber:
    def __init__(self, model_name="mlx-community/whisper-large-v3-mlx"):
        self.model_name = model_name
        self.model = None
        print(f"Initializing Whisper model: {model_name}...")

    def load_model(self):
        """Loads the model if not already loaded."""
        if self.model is None:
            # mlx-whisper loads the model on the first call to transcribe too,
            # but we can pre-load or just let it handle it.
            # Using mlx-whisper directly.
            pass

    def transcribe(self, audio_data, initial_prompt=None, condition_on_previous_text=True):
        """
        Transcribes audio data.
        audio_data: numpy array (16kHz, float32)
        """
        if audio_data is None or len(audio_data) == 0:
            return ""

        print("Transcribing...")
        start_time = time.time()
        
        # MLX Whisper transcribe options
        # We don't specify language to allow auto-detection, 
        # but we use initial_prompt and condition_on_previous_text to guide it.
        result = mlx_whisper.transcribe(
            audio_data,
            path_or_hf_repo=self.model_name,
            initial_prompt=initial_prompt,
            condition_on_previous_text=condition_on_previous_text,
            task="transcribe",
            verbose=False
        )
        
        end_time = time.time()
        print(f"Transcription finished in {end_time - start_time:.2f} seconds.")
        
        return result.get("text", "").strip()

if __name__ == "__main__":
    # Test with dummy data
    transcriber = WhisperTranscriber()
    dummy_audio = np.zeros(16000 * 2, dtype=np.float32)
    text = transcriber.transcribe(dummy_audio)
    print(f"Result: {text}")
