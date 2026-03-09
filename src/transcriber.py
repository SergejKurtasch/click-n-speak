import mlx_whisper
import time
import numpy as np

class WhisperTranscriber:
    def __init__(self, model_name="mlx-community/whisper-large-v3-mlx"):
        self.model_name = model_name
        print(f"Initializing Whisper model: {model_name}...")

    def transcribe(self, audio_data, initial_prompt=None, condition_on_previous_text=True):
        """
        Transcribes audio data using MLX Whisper.
        audio_data: numpy array (16kHz, float32)
        """
        if audio_data is None or len(audio_data) == 0:
            return ""

        print("Transcribing...")
        start_time = time.time()
        
        try:
            # MLX Whisper transcribe options
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
        except Exception as e:
            print(f"Transcription error: {e}")
            return ""
