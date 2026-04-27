import re
import time
import multiprocessing as mp
import queue
import traceback

import numpy as np

from .process_watchdog import install_parent_death_watchdog
from .utils import log_error, log_exception, log_info

# Maximum seconds to wait for transcriber process to respond before killing it
TRANSCRIBER_TIMEOUT_SECONDS = 30

# Final chunks shorter than this (in samples at 16kHz) are skipped — they are
# almost always silence/noise that cause Whisper to hallucinate for 10-43 seconds.
MIN_FINAL_CHUNK_SAMPLES = 4800  # 0.3 seconds at 16 kHz

# Strip leading/trailing punctuation so "hundred", "hundred!", "hundred." count as same word
_WORD_NORMALIZE = re.compile(r"^[\W_]+|[\W_]+$")


def _normalize_word(w: str) -> str:
    """Lowercase and strip punctuation for repetition comparison."""
    return _WORD_NORMALIZE.sub("", w.lower())


def _collapse_consecutive_word_repetition(text: str) -> str:
    """Collapse runs of consecutive identical words to a single occurrence.

    Handles two cases:
    1. Real Whisper hallucination: model loops on same word dozens of times.
    2. Sentence boundary: "...купить машину. Машину красного..." — should NOT be dropped.
    In both cases collapsing is safer than discarding the whole chunk.
    """
    words = text.split()
    if not words:
        return text
    result = [words[0]]
    prev = _normalize_word(words[0])
    for w in words[1:]:
        curr = _normalize_word(w)
        if curr and curr == prev:
            continue  # skip duplicate, keep first occurrence
        result.append(w)
        prev = curr
    return " ".join(result)


def _call_mlx_transcribe(
    audio_data,
    model_name: str,
    initial_prompt=None,
    condition_on_previous_text=True,
    verbose=False,
    **extra_kwargs,
):
    """Call mlx_whisper.transcribe; fall back without extra_kwargs if API does not support them."""
    try:
        import mlx_whisper  # type: ignore
    except ImportError as exc:
        raise RuntimeError("mlx_whisper is not installed — cannot transcribe.") from exc

    base_kw = {
        "path_or_hf_repo": model_name,
        "initial_prompt": initial_prompt,
        "condition_on_previous_text": condition_on_previous_text,
        "task": "transcribe",
        "verbose": verbose,
    }
    try:
        return mlx_whisper.transcribe(audio_data, **base_kw, **extra_kwargs)
    except TypeError:
        # Older mlx_whisper may not accept no_speech_threshold / compression_ratio_threshold
        log_info("mlx_whisper.transcribe does not accept strict thresholds; using defaults.")
        return mlx_whisper.transcribe(audio_data, **base_kw)


class WhisperTranscriber:
    def __init__(self, model_name="mlx-community/whisper-large-v3-turbo"):
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
            "by the amara",
            "y cómo va a funcionar",
            "subtitles",
            "субтитры подогнал",
            "подогнал симон",
            "десерт",
            "субтитры подготовил",
            "субтитры сделал",
            "субтитры создавал",
            "субтитры создал",
            "субтитры",
            "редактор субтитров",
            "перевод на русский",
        }
        log_info(f"Initializing Whisper model: {model_name}...")

    def warmup(self, duration_seconds: float = 0.5, sample_rate: int = 16000, language: str = None) -> None:
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
            f"Warming up Whisper model (silence transcription to initialize MLX with language={language})..."
        )
        
        warmup_kw = {
            "no_speech_threshold": 0.5,
            "compression_ratio_threshold": 2.0
        }
        if language:
            warmup_kw["language"] = language

        _ = _call_mlx_transcribe(
            audio_data,
            model_name=self.model_name,
            initial_prompt=None,
            condition_on_previous_text=True,
            **warmup_kw,
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

        # Skip very short final chunks — they are almost always post-speech silence
        # that Whisper decodes into hallucinations (10-43 seconds of wasted time).
        if is_final_chunk and len(audio_data) < MIN_FINAL_CHUNK_SAMPLES:
            log_info(
                f"Skipping tiny final chunk ({len(audio_data)} samples, "
                f"{len(audio_data) / 16000:.2f}s) to avoid hallucination."
            )
            return ""

        # Stricter thresholds for short/final chunks to reduce long hallucination decoding (15-27s)
        # Applied to: final chunks, and any audio shorter than ~5s (80000 samples at 16kHz)
        use_strict_thresholds = is_final_chunk or len(audio_data) < 80000
        whisper_kw: dict = {}
        if use_strict_thresholds:
            whisper_kw["no_speech_threshold"] = 0.5
            whisper_kw["compression_ratio_threshold"] = 2.0

        # Only force the Whisper language token if there is exactly ONE allowed language.
        # If the user selected additional languages, we must let Whisper auto-detect 
        # (the initial_prompt with multiple language hints will guide it).
        if allowed_languages and len(allowed_languages) == 1:
            whisper_kw["language"] = allowed_languages[0]

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

            # Filter out chunks that were recognized in another language (model was told primary via language=; we drop the rest).
            # Skip for final chunk so we never lose the end of the phrase; skip for trivial text (punctuation only or single word).
            words = text.split()
            is_trivial = len(words) <= 1 or not any(w.isalnum() for w in words)
            apply_lang_filter = (
                allowed_languages
                and not is_final_chunk
                and not is_trivial
            )
            if apply_lang_filter:
                detected_lang = result.get("language", "").lower()
                if detected_lang:
                    if detected_lang not in allowed_languages:
                        is_allowed = False
                        for allowed in allowed_languages:
                            if allowed in detected_lang or detected_lang in allowed:
                                is_allowed = True
                                break
                        if not is_allowed:
                            log_info(
                                f"Segment recognized as '{detected_lang}', retrying transcription with 0.1s padding..."
                            )
                            # Pad audio with 0.1s of silence (1600 samples at 16kHz) at both ends
                            # to shift the decoding window and potentially change the output language.
                            padded_audio = np.pad(audio_data, (1600, 1600), "constant")
                            result = _call_mlx_transcribe(
                                padded_audio,
                                model_name=self.model_name,
                                initial_prompt=initial_prompt,
                                condition_on_previous_text=condition_on_previous_text,
                                **whisper_kw,
                            )
                            text = result.get("text", "").strip()
                            if text:
                                words = text.split()
                                is_trivial = len(words) <= 1 or not any(
                                    w.isalnum() for w in words
                                )
                                retry_lang = result.get("language", "").lower()
                                if retry_lang and retry_lang in allowed_languages:
                                    log_info(
                                        f"Retry returned allowed language '{retry_lang}': '{text[:50]}...'"
                                    )
                                else:
                                    log_info(
                                        "Retry used (keeping text to avoid losing chunk)."
                                    )
                                apply_lang_filter = False
                            else:
                                log_info("Retry returned empty text; dropping chunk.")
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

            # Phrase list: filter for both normal and final chunk (thank you, etc.)
            for phrase in self.hallucination_phrases:
                if phrase in clean_text_lower:
                    log_info(
                        f"Filtered out hallucination containing '{phrase}': '{text}'"
                    )
                    return ""

            # Single-word "you"/"the": filter for normal chunks only; allow for final
            # so we do not drop real short endings when Whisper hallucinates "you"
            if not is_final_chunk and clean_text_lower.strip(" .") in ("you", "the"):
                log_info(
                    f"Filtered out likely single-word hallucination: '{text}'"
                )
                return ""

            collapsed = _collapse_consecutive_word_repetition(text)
            if collapsed != text:
                log_info(
                    f"Collapsed consecutive word repetition: '{text}' → '{collapsed}'"
                )
                text = collapsed

            if is_final_chunk:
                log_info(f"Final chunk: keeping after light filter: '{text}'")

            # Final cleanup: strip leading/trailing dots, ellipses and spaces
            return text.strip(" .…")
        except Exception as e:
            # Log full traceback to help diagnose rare crashes inside mlx_whisper
            log_exception(f"Transcription error with model {self.model_name}: {e}")
            return ""

    def transcribe_file(self, file_path: str, initial_prompt=None, allowed_languages=None):
        """Transcribe a full audio file directly."""
        if not file_path:
            return ""

        whisper_kw: dict = {}
        if allowed_languages and len(allowed_languages) == 1:
            whisper_kw["language"] = allowed_languages[0]

        log_info(
            f"Transcribing audio file with Whisper: '{file_path}', "
            f"model={self.model_name}, allowed_languages={allowed_languages}"
        )
        start_time = time.time()
        try:
            result = _call_mlx_transcribe(
                file_path,
                model_name=self.model_name,
                initial_prompt=initial_prompt,
                condition_on_previous_text=False,
                verbose=True,
                **whisper_kw,
            )
            
            end_time = time.time()
            log_info(f"File transcription finished in {end_time - start_time:.2f} seconds.")

            text = result.get("text", "").strip()
            return text.strip(" .…")
        except Exception as e:
            log_exception(f"File transcription error with model {self.model_name}: {e}")
            return ""


class TranscriberProcessWrapper:
    """Runs WhisperTranscriber in a dedicated child process to avoid blocking the main UI loop with the GIL."""
    def __init__(self, model_name="mlx-community/whisper-large-v3-turbo"):
        self.input_queue = mp.Queue()
        self.output_queue = mp.Queue()
        self.model_name = model_name
        
        # Start child process
        self._process = mp.Process(target=self._run_loop, daemon=True)
        self._process.start()

    def _run_loop(self):
        # Parent-death watchdog: macOS has no PR_SET_PDEATHSIG, and a daemon
        # mp.Process only dies via atexit in the parent — which is skipped on
        # SIGKILL, crash, Force Quit, or NSApp.terminate without cleanup. Without
        # this watchdog each crashed session leaves behind a 2-4 GB orphan holding
        # the MLX model in memory.
        import os as _os
        log_info(
            f"Transcriber child process started: pid={_os.getpid()} "
            f"ppid={_os.getppid()} pgid={_os.getpgrp()} model={self.model_name}"
        )
        install_parent_death_watchdog()

        try:
            transcriber = WhisperTranscriber(model_name=self.model_name)
        except Exception as e:
            self.output_queue.put({"type": "error", "message": str(e), "trace": traceback.format_exc()})
            return

        while True:
            try:
                cmd = self.input_queue.get()
                if cmd is None:
                    break
                
                action = cmd.get("action")
                if action == "warmup":
                    transcriber.warmup(language=cmd.get("language"))
                    self.output_queue.put({"type": "warmup_done"})
                elif action == "prewarm":
                    # Run a real short transcription on silence to bring GPU/MLX weights
                    # back into active memory. Fire-and-forget: result is discarded.
                    silence = np.zeros(16000, dtype=np.float32)  # 1s at 16kHz
                    transcriber.transcribe(silence, is_final_chunk=False)
                    self.output_queue.put({"type": "prewarm_done"})
                elif action == "transcribe":
                    text = transcriber.transcribe(
                        cmd.get("audio_data"),
                        initial_prompt=cmd.get("initial_prompt"),
                        allowed_languages=cmd.get("allowed_languages"),
                        condition_on_previous_text=cmd.get("condition_on_previous_text", True),
                        is_final_chunk=cmd.get("is_final_chunk", False)
                    )
                    self.output_queue.put({
                        "type": "transcription",
                        "text": text,
                        "is_final_chunk": cmd.get("is_final_chunk", False)
                    })
                elif action == "transcribe_file":
                    text = transcriber.transcribe_file(
                        cmd.get("file_path"),
                        initial_prompt=cmd.get("initial_prompt"),
                        allowed_languages=cmd.get("allowed_languages")
                    )
                    self.output_queue.put({
                        "type": "transcription",
                        "text": text,
                        "is_final_chunk": True
                    })
                elif action == "update_model":
                    transcriber = WhisperTranscriber(model_name=cmd["model_name"])
                elif action == "clear_cache":
                    try:
                        import mlx.core
                        mlx.core.metal.clear_cache()
                        log_info("MLX Metal cache cleared.")
                    except Exception as e:
                        log_info(f"clear_cache skipped: {e}")
            except KeyboardInterrupt:
                break
            except Exception as e:
                self.output_queue.put({"type": "error", "message": str(e), "trace": traceback.format_exc()})

    def stop(self):
        try:
            self.input_queue.put_nowait(None)
        except Exception:
            pass
        self._process.join(timeout=3.0)
        if self._process.is_alive():
            self._process.terminate()
            self._process.join(timeout=3.0)
        if self._process.is_alive():
            self._process.kill()
            self._process.join(timeout=2.0)
        if self._process.is_alive():
            log_error("Transcriber process still alive after SIGKILL — giving up.")
        
    def warmup(self, language=None):
        self.input_queue.put({"action": "warmup", "language": language})

    def pre_warm(self) -> None:
        """Fire-and-forget: push a tiny silent transcription to the child process so
        GPU/MLX model weights are in active memory before the first real chunk arrives.
        The prewarm_done response will be silently consumed by the next transcribe() call."""
        self.input_queue.put({"action": "prewarm"})
        
    def clear_cache(self) -> None:
        """Free MLX Metal buffer pool in the child process after a session ends."""
        self.input_queue.put({"action": "clear_cache"})

    def update_model(self, model_name: str) -> None:
        """Tell the child process to load a new model."""
        self.model_name = model_name
        self.input_queue.put({"action": "update_model", "model_name": model_name})
        
    def _restart_process(self) -> None:
        """Kill the hung child process and start a fresh one."""
        log_info("Restarting transcriber process after timeout...")
        try:
            self._process.kill()
            self._process.join(timeout=2.0)
        except Exception as e:
            log_error(f"Error killing transcriber process: {e}")
        # Replace queues entirely — draining is racy (new items can arrive between
        # get_nowait() and process restart). New objects guarantee a clean slate.
        self.input_queue = mp.Queue()
        self.output_queue = mp.Queue()
        self._process = mp.Process(target=self._run_loop, daemon=True)
        self._process.start()
        log_info("Transcriber process restarted.")

    def transcribe(self, audio_data, initial_prompt=None, allowed_languages=None, condition_on_previous_text=True, is_final_chunk=False):
        """Blocking call to transcribe the given audio chunk using the child process.

        If the child process does not respond within TRANSCRIBER_TIMEOUT_SECONDS,
        the process is killed and restarted, and an empty string is returned.
        """
        self.input_queue.put({
            "action": "transcribe",
            "audio_data": audio_data,
            "initial_prompt": initial_prompt,
            "allowed_languages": allowed_languages,
            "condition_on_previous_text": condition_on_previous_text,
            "is_final_chunk": is_final_chunk
        })
        # Wait for result with a hard timeout to prevent infinite hangs
        deadline = time.time() + TRANSCRIBER_TIMEOUT_SECONDS
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                log_error(
                    f"Transcriber process did not respond within {TRANSCRIBER_TIMEOUT_SECONDS}s. "
                    "Killing and restarting process."
                )
                self._restart_process()
                return ""
            try:
                poll_timeout = min(0.1, remaining)
                res = self.output_queue.get(timeout=poll_timeout)
                if res["type"] == "transcription":
                    return res["text"]
                elif res["type"] == "error":
                    log_error(f"Transcriber process error: {res['message']}\n{res.get('trace')}")
                    return ""
                # Ignore warmup_done or other messages if they accidentally arrive during transcribe
            except queue.Empty:
                continue

    def transcribe_file(self, file_path, initial_prompt=None, allowed_languages=None):
        """Blocking call to transcribe the given audio file using the child process.
        
        Uses a very long timeout (3600s) since files can be arbitrarily large.
        """
        self.input_queue.put({
            "action": "transcribe_file",
            "file_path": file_path,
            "initial_prompt": initial_prompt,
            "allowed_languages": allowed_languages,
        })
        # Wait for result with a hard timeout of 1 hour to prevent infinite file processing hangs
        deadline = time.time() + 3600
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                log_error(
                    "Transcriber process did not respond within 3600s for audio file. "
                    "Killing and restarting process."
                )
                self._restart_process()
                return ""
            try:
                poll_timeout = min(0.1, remaining)
                res = self.output_queue.get(timeout=poll_timeout)
                if res["type"] == "transcription":
                    return res["text"]
                elif res["type"] == "error":
                    log_error(f"Transcriber process error: {res['message']}\n{res.get('trace')}")
                    return ""
            except queue.Empty:
                continue
