import mlx_whisper
import time
import numpy as np

class WhisperTranscriber:
    def __init__(self, model_name="mlx-community/whisper-large-v3-mlx"):
        self.model_name = model_name
        # Common hallucinations/noise results to filter out (no trailing punctuation)
        self.hallucinations = {
            "thank you", "thank you for watching", "thanks for watching",
            "благодарю", "благодарю за внимание", "подпишитесь на канал",
            "продолжение следует", "продолжение следует...", "you", "bye", 
            "subscribe", "thanks", "redacted", "captioning by", "translated by",
            "insert", "direct"
        }
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
            
            text = result.get("text", "").strip()
            
            # Filtering hallucinations
            clean_text = text.lower().strip(" .!?,")
            if clean_text in self.hallucinations or not clean_text:
                if text:
                    print(f"Filtered out hallucination: '{text}'")
                return ""
            
            # Final cleanup: strip leading/trailing dots, ellipses and spaces
            return text.strip(" .…")
        except Exception as e:
            print(f"Transcription error: {e}")
            return ""
