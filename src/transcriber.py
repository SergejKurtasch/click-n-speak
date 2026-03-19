import re
import time

import numpy as np
import mlx_whisper

from .utils import log_error, log_exception, log_info

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


def _call_mlx_transcribe(
    audio_data,
    model_name: str,
    initial_prompt=None,
    condition_on_previous_text=True,
    **extra_kwargs,
):
    """Call mlx_whisper.transcribe; fall back without extra_kwargs if API does not support them."""
    base_kw = {
        "path_or_hf_repo": model_name,
        "initial_prompt": initial_prompt,
        "condition_on_previous_text": condition_on_previous_text,
        "task": "transcribe",
        "verbose": False,
    }
    try:
        return mlx_whisper.transcribe(audio_data, **base_kw, **extra_kwargs)
    except TypeError:
        # Older mlx_whisper may not accept no_speech_threshold / compression_ratio_threshold
        log_info("mlx_whisper.transcribe does not accept strict thresholds; using defaults.")
        return mlx_whisper.transcribe(audio_data, **base_kw)


class WhisperTranscriber:
    def __init__(self, model_name="mlx-community/whisper-large-v3-mlx"):
        self.model_name = model_name
        self._warmup_done = False
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
            "субтитры подогнал",
            "подогнал симон",
            "heed",
        }
        log_info(f"Initializing Whisper model: {model_name}...")

    def warmup(self, duration_seconds: float = 0.5, sample_rate: int = 16000) -> None:
        """Warm up the MLX Whisper model to reduce the first-use latency.

        This runs a tiny transcription on silence and discards the result.
        """
        if self._warmup_done:
            return

        if duration_seconds <= 0:
            duration_seconds = 0.1

        # Silence audio for a quick model initialization / compilation path.
        audio_len = max(1, int(sample_rate * duration_seconds))
        audio_data = np.zeros((audio_len,), dtype=np.float32)

        log_info(
            "Warming up Whisper model (silence transcription to initialize MLX)..."
        )
        _ = mlx_whisper.transcribe(
            audio_data,
            path_or_hf_repo=self.model_name,
            task="transcribe",
            verbose=False,
        )
        self._warmup_done = True

    def transcribe(
        self,
        audio_data,
        initial_prompt=None,
        allowed_languages=None,
        condition_on_previous_text=True,
        is_final_chunk=False,
    ):
        """
        Transcribes audio data using MLX Whisper.
        audio_data: numpy array (16kHz, float32)
        is_final_chunk: if True, do not filter out short or common-hallucination text
                        so the user's last words are never dropped.
        """
        if audio_data is None or len(audio_data) == 0:
            return ""

        # Stricter thresholds for short/final chunks to reduce long hallucination decoding (15-27s)
        use_strict_thresholds = is_final_chunk or len(audio_data) < 48000  # 48000 samples ~ 3s at 16kHz
        whisper_kw: dict = {}
        if use_strict_thresholds:
            whisper_kw["no_speech_threshold"] = 0.5
            whisper_kw["compression_ratio_threshold"] = 2.0

        log_info(
            "Transcribing audio chunk with Whisper: "
            f"len={len(audio_data)}, "
            f"model={self.model_name}, "
            f"allowed_languages={allowed_languages}, "
            f"condition_on_previous_text={condition_on_previous_text}, "
            f"initial_prompt_len={len(initial_prompt) if initial_prompt else 0}"
            + (", is_final_chunk=True" if is_final_chunk else "")
            + (", strict_thresholds=True" if use_strict_thresholds else "")
        )
        start_time = time.time()

        try:
            result = _call_mlx_transcribe(
                audio_data,
                model_name=self.model_name,
                initial_prompt=initial_prompt,
                condition_on_previous_text=condition_on_previous_text,
                **whisper_kw,
            )
            log_info(
                f"transcribe returned (len={len(audio_data)}, is_final_chunk={is_final_chunk})"
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

            # Hallucination filtering. For final chunk we still filter obvious garbage
            # (phrase list, single-word you/the, repetition) so we keep short real phrases.
            clean_text_lower = text.lower()

            if not is_final_chunk:
                # Suspicious CJK only for non-final (aggressive filter)
                asian_chars = sum(1 for c in text if "\u4e00" <= c <= "\u9fff")
                if asian_chars > 2 and asian_chars > (len(text) / 3):
                    log_info(f"Filtered out suspicious Asian characters: '{text}'")
                    return ""

            # Phrase list and single-word you/the: filter for both normal and final chunk
            for phrase in self.hallucination_phrases:
                if phrase in clean_text_lower:
                    log_info(
                        f"Filtered out hallucination containing '{phrase}': '{text}'"
                    )
                    return ""

            if clean_text_lower.strip(" .") in ("you", "the"):
                log_info(
                    f"Filtered out likely single-word hallucination: '{text}'"
                )
                return ""

            if _has_consecutive_word_repetition(
                text, CONSECUTIVE_REPEAT_HALLUCINATION_THRESHOLD
            ):
                log_info(
                    f"Filtered out hallucination (consecutive word repetition): '{text}'"
                )
                return ""

            if is_final_chunk:
                log_info(f"Final chunk: keeping after light filter: '{text}'")

            # Final cleanup: strip leading/trailing dots, ellipses and spaces
            return text.strip(" .…")
        except Exception as e:
            # Log full traceback to help diagnose rare crashes inside mlx_whisper
            log_exception(f"Transcription error with model {self.model_name}: {e}")
            return ""
