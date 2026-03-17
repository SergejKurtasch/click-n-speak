import re
import time

import mlx_whisper

from .utils import log_error, log_info

# Consecutive same-word repeats at or above this count are treated as hallucination
CONSECUTIVE_REPEAT_HALLUCINATION_THRESHOLD = 2

# Strip leading/trailing punctuation so "hundred", "hundred!", "hundred." count as same word
_WORD_NORMALIZE = re.compile(r"^[\W_]+|[\W_]+$")


def _normalize_word(w: str) -> str:
    """Lowercase and strip punctuation for repetition comparison."""
    return _WORD_NORMALIZE.sub("", w.lower())


def _has_consecutive_word_repetition(text: str, threshold: int = CONSECUTIVE_REPEAT_HALLUCINATION_THRESHOLD) -> bool:
    """Return True if the same word appears at least `threshold` times in a row (hallucination indicator)."""
    words = text.split()
    if len(words) < threshold:
        return False
    count = 1
    prev = _normalize_word(words[0])
    for i in range(1, len(words)):
        curr = _normalize_word(words[i])
        if curr and curr == prev:
            count += 1
            if count >= threshold:
                return True
        else:
            count = 1
            prev = curr
    return False


class WhisperTranscriber:
    def __init__(self, model_name="mlx-community/whisper-large-v3-mlx"):
        self.model_name = model_name
        # Common hallucinations/noise results to filter out (substring matches)
        self.hallucination_phrases = {
            "thank you",
            "thanks for watching",
            "благодарю",
            "подпишитесь",
            "продолжение следует",
            "subtitles by",
            "amara.org",
            "the amara.org community",
            "captioning by",
            "translated by",
            "don't forget to",
            "you for watching",
            "a s s u b t i t l e s",
            "insert",
            "direct",
            "by the amara",
            "y cómo va a funcionar",
            "subtitles",
            "watching",
            "subscribe",
        }
        log_info(f"Initializing Whisper model: {model_name}...")

    def transcribe(self, audio_data, initial_prompt=None, allowed_languages=None, condition_on_previous_text=True):
        """
        Transcribes audio data using MLX Whisper.
        audio_data: numpy array (16kHz, float32)
        """
        if audio_data is None or len(audio_data) == 0:
            return ""

        log_info("Transcribing...")
        start_time = time.time()

        try:
            # MLX Whisper transcribe options (verbose=True to get language info in logs if needed)
            result = mlx_whisper.transcribe(
                audio_data,
                path_or_hf_repo=self.model_name,
                initial_prompt=initial_prompt,
                condition_on_previous_text=condition_on_previous_text,
                task="transcribe",
                verbose=False,
            )

            end_time = time.time()
            log_info(f"Transcription finished in {end_time - start_time:.2f} seconds.")

            text = result.get("text", "").strip()
            if not text:
                return ""

            # Language filtering logic
            # Map of Whisper language codes to common names if needed, but Whisper usually returns codes
            detected_lang = result.get("language", "").lower()
            if allowed_languages and detected_lang:
                # Some versions might return "en" vs "english"
                if detected_lang not in allowed_languages:
                    # Check if the code is a prefix or vice-versa (e.g., 'en' in 'english')
                    is_allowed = False
                    for allowed in allowed_languages:
                        if allowed in detected_lang or detected_lang in allowed:
                            is_allowed = True
                            break
                    if not is_allowed:
                        log_info(f"Filtered out unauthorized language '{detected_lang}': '{text}'")
                        return ""

            # Check for suspicious characters (like excessive CJK characters in non-CJK context)
            # This is common for Whisper hallucinations
            clean_text_lower = text.lower()

            # Simple check for Chinese characters (common hallucination)
            # Unicode range for CJK: \u4e00-\u9fff
            asian_chars = sum(1 for c in text if "\u4e00" <= c <= "\u9fff")
            if asian_chars > 2 and asian_chars > (len(text) / 3):
                log_info(f"Filtered out suspicious Asian characters: '{text}'")
                return ""

            # Filtering hallucinations using substring matching
            for phrase in self.hallucination_phrases:
                if phrase in clean_text_lower:
                    log_info(f"Filtered out hallucination containing '{phrase}': '{text}'")
                    return ""

            # Special case for "you" or "you." as it's a very common Whisper hallucination
            # if it's the ONLY word in the result.
            if clean_text_lower.strip(" .") == "you":
                log_info(f"Filtered out likely 'you' hallucination: '{text}'")
                return ""

            # Consecutive same-word repetition (e.g. "word word word") is a common hallucination
            if _has_consecutive_word_repetition(text, CONSECUTIVE_REPEAT_HALLUCINATION_THRESHOLD):
                log_info(f"Filtered out hallucination (consecutive word repetition): '{text}'")
                return ""

            # Final cleanup: strip leading/trailing dots, ellipses and spaces
            return text.strip(" .…")
        except Exception as e:
            log_error(f"Transcription error: {e}")
            return ""
