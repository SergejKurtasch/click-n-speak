"""Cloud speech-to-text backends (Gemini, OpenAI).

Provides CloudSTTTranscriber, a duck-typed drop-in replacement for
TranscriberProcessWrapper (see transcriber.py) that sends audio chunks to a
cloud API instead of running mlx_whisper locally. Selected via
config["stt_backend"] ("gemini" | "openai") and config["stt_cloud_model"].
"""

import io
import os
import queue
import subprocess
import threading
import time
import wave
from typing import Optional

import numpy as np

from .ai_editor import get_gemini_api_key
from .transcriber import FileTranscriptionError, MIN_FINAL_CHUNK_SAMPLES, _is_audio_silent
from .utils import LANG_NAMES, log_error, log_info

# ---------------------------------------------------------------------------
# Cloud STT model registry
# ---------------------------------------------------------------------------
CLOUD_STT_MODELS: dict[str, list[tuple[str, str]]] = {
    "gemini": [
        ("Gemini 2.5 Flash-Lite", "gemini-2.5-flash-lite"),
        ("Gemini 2.5 Flash", "gemini-2.5-flash"),
        ("Gemini 3 Flash", "gemini-3-flash"),
    ],
    "openai": [
        ("GPT-4o mini Transcribe", "gpt-4o-mini-transcribe"),
        ("GPT-4o Transcribe", "gpt-4o-transcribe"),
        ("Whisper-1", "whisper-1"),
    ],
}

DEFAULT_CLOUD_STT_MODEL = "gemini-2.5-flash-lite"

# Per-chunk / file timeouts (seconds). Mirrors the thread+join pattern used by
# GeminiEditor.refine() — the HTTP call runs in a daemon thread; on timeout we
# return "" (or raise for files) and let the thread finish in the background.
_CLOUD_STT_TIMEOUT_SECONDS = 25.0
_CLOUD_STT_FILE_TIMEOUT_SECONDS = 300.0

# Same short-chunk silence guard as WhisperTranscriber.transcribe() — avoids
# spending an API call on pure microphone noise.
_SHORT_CHUNK_SAMPLES = 48000  # 3 seconds at 16 kHz

# ---------------------------------------------------------------------------
# OpenAI API key storage (Keychain, same pattern as get/set_gemini_api_key)
# ---------------------------------------------------------------------------
_KEYCHAIN_SERVICE = "click-n-speak"
_OPENAI_KEYCHAIN_ACCOUNT = "openai_api_key"
_SECURITY_BIN = "/usr/bin/security"


def get_openai_api_key() -> str | None:
    """Return OpenAI API key: env var first, then macOS Keychain via security CLI."""
    key = os.environ.get("OPENAI_API_KEY")
    if key:
        return key.strip() or None
    try:
        result = subprocess.run(
            [_SECURITY_BIN, "find-generic-password",
             "-s", _KEYCHAIN_SERVICE, "-a", _OPENAI_KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except Exception as e:
        log_info(f"Keychain read skipped: {e}")
    return None


def set_openai_api_key(key: str) -> None:
    """Store OpenAI API key in macOS Keychain via security CLI. Raises on failure."""
    try:
        result = subprocess.run(
            [_SECURITY_BIN, "add-generic-password",
             "-s", _KEYCHAIN_SERVICE, "-a", _OPENAI_KEYCHAIN_ACCOUNT, "-w", "-", "-U"],
            input=key, capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "security command failed")
    except subprocess.TimeoutExpired as e:
        raise RuntimeError("Keychain access timed out") from e
    except FileNotFoundError as e:
        raise RuntimeError(f"{_SECURITY_BIN} not found") from e


# ---------------------------------------------------------------------------
# Audio encoding
# ---------------------------------------------------------------------------

def numpy_to_wav_bytes(audio: np.ndarray, sample_rate: int = 16000) -> bytes:
    """Encode a float32 [-1, 1] mono audio array as 16-bit PCM WAV bytes."""
    pcm16 = np.clip(audio, -1.0, 1.0)
    pcm16 = (pcm16 * 32767.0).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm16.tobytes())
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------
_STT_INSTRUCTION = (
    "Transcribe the following audio recording in the language it is spoken in. "
    "Produce a lightly cleaned transcript: remove verbal filler and hesitation "
    "sounds (e.g. \"um\", \"uh\", \"er\", Russian \"э\", \"эм\", \"ну\", \"вот\", "
    "\"типа\", \"как бы\" when used purely as filler) and false-start word or "
    "phrase repetitions where the speaker corrects themselves mid-sentence. "
    "Do not remove, shorten, paraphrase, summarize, or translate anything else — "
    "keep every meaningful word, name, number, and technical term exactly as "
    "spoken, in the original order. Do not invent words that were not said. "
    "Output only the cleaned transcription text, with no commentary, labels, "
    "quotation marks, or markdown formatting."
)

# Shorter cleanup hint for OpenAI's `prompt` parameter (gpt-4o-*-transcribe models
# follow it as an instruction; whisper-1 treats it as prior-text style context,
# so it is not used there — see _build_openai_prompt).
_STT_CLEANUP_HINT_OPENAI = (
    "Clean up filler words and hesitation sounds (um, uh, э, ну, вот, типа, как бы) "
    "and false-start repetitions, but keep all other words, names, numbers and "
    "terms exactly as spoken. Do not paraphrase or summarize."
)


def _build_stt_prompt(initial_prompt: Optional[str], allowed_languages: Optional[list[str]]) -> str:
    parts = [_STT_INSTRUCTION]
    if allowed_languages:
        names = ", ".join(LANG_NAMES.get(code, code) for code in allowed_languages)
        parts.append(f"The speaker is likely using one of these languages: {names}.")
    if initial_prompt:
        parts.append(f"Context and vocabulary hints (do not transcribe this part itself): {initial_prompt}")
    return "\n".join(parts)


def _build_openai_prompt(model_name: str, initial_prompt: Optional[str]) -> Optional[str]:
    """Build the `prompt` kwarg for OpenAI transcriptions.

    gpt-4o-*-transcribe models follow instructions in the prompt, so the
    filler-word cleanup hint is prepended there. whisper-1 only uses the
    prompt as prior-text style/vocabulary context (it does not follow
    instructions), so it gets the vocabulary hint alone.
    """
    parts: list[str] = []
    if model_name != "whisper-1":
        parts.append(_STT_CLEANUP_HINT_OPENAI)
    if initial_prompt:
        parts.append(initial_prompt)
    if not parts:
        return None
    return " ".join(parts)[:800]


# ---------------------------------------------------------------------------
# CloudSTTTranscriber
# ---------------------------------------------------------------------------

class CloudSTTTranscriber:
    """Duck-typed drop-in for TranscriberProcessWrapper using a cloud STT API.

    No child process is spawned — API calls run directly on the calling
    (chunk worker) thread, guarded by a thread+join timeout.
    """

    def __init__(self, backend: str, model_name: str) -> None:
        self.backend = backend  # "gemini" | "openai"
        self.model_name = model_name
        self.last_detected_language: str = ""
        self._last_transcribe_returned_at: float = 0.0
        # Dummy queues so call sites that poll transcriber.output_queue
        # (e.g. _model_warmup_worker's drain loop after warmup()) keep working.
        self.input_queue: "queue.Queue" = queue.Queue()
        self.output_queue: "queue.Queue" = queue.Queue()

    # -- lifecycle no-ops (mirroring TranscriberProcessWrapper interface) --
    def stop(self) -> None:
        pass

    def _restart_process(self) -> None:
        pass

    def pre_warm(self) -> None:
        pass

    def clear_cache(self) -> None:
        pass

    def warmup(self, language: Optional[str] = None) -> None:
        self.output_queue.put({"type": "warmup_done"})

    def update_model(self, model_name: str) -> None:
        self.model_name = model_name

    # -- transcription --
    def transcribe(
        self,
        audio_data,
        initial_prompt=None,
        allowed_languages=None,
        condition_on_previous_text=True,
        is_final_chunk=False,
        timeout_override: Optional[float] = None,
    ) -> str:
        if is_final_chunk and len(audio_data) <= MIN_FINAL_CHUNK_SAMPLES:
            return ""
        if not is_final_chunk and len(audio_data) < _SHORT_CHUNK_SAMPLES and _is_audio_silent(audio_data):
            return ""

        wav_bytes = numpy_to_wav_bytes(audio_data)
        prompt = _build_stt_prompt(initial_prompt, allowed_languages)

        result: list[str] = []
        exc: list[Exception] = []

        def _run() -> None:
            try:
                if self.backend == "gemini":
                    result.append(self._call_gemini(wav_bytes, prompt))
                else:
                    result.append(self._call_openai(wav_bytes, initial_prompt, allowed_languages))
            except Exception as e:
                exc.append(e)

        t = threading.Thread(target=_run, daemon=True)
        t.start()
        t.join(timeout=_CLOUD_STT_TIMEOUT_SECONDS)

        if t.is_alive():
            log_error(f"CloudSTTTranscriber [{self.backend}/{self.model_name}]: request timed out after {_CLOUD_STT_TIMEOUT_SECONDS:.0f}s.")
            return ""
        if exc:
            log_error(f"CloudSTTTranscriber [{self.backend}/{self.model_name}]: transcription failed: {exc[0]}")
            return ""

        self._last_transcribe_returned_at = time.time()
        return (result[0] if result else "").strip()

    def transcribe_file(self, file_path, initial_prompt=None, allowed_languages=None) -> str:
        prompt = _build_stt_prompt(initial_prompt, allowed_languages)

        result: list[str] = []
        exc: list[Exception] = []

        def _run() -> None:
            try:
                if self.backend == "gemini":
                    result.append(self._call_gemini_file(file_path, prompt))
                else:
                    result.append(self._call_openai_file(file_path, initial_prompt, allowed_languages))
            except Exception as e:
                exc.append(e)

        t = threading.Thread(target=_run, daemon=True)
        t.start()
        t.join(timeout=_CLOUD_STT_FILE_TIMEOUT_SECONDS)

        if t.is_alive():
            raise FileTranscriptionError(
                f"Cloud transcription timed out after {_CLOUD_STT_FILE_TIMEOUT_SECONDS:.0f}s."
            )
        if exc:
            raise FileTranscriptionError(str(exc[0])) from exc[0]
        return (result[0] if result else "").strip()

    # -- Gemini backend --
    def _call_gemini(self, wav_bytes: bytes, prompt: str) -> str:
        from google import genai
        from google.genai import types

        api_key = get_gemini_api_key()
        if not api_key:
            raise RuntimeError("No Gemini API key configured.")

        client = genai.Client(api_key=api_key)
        response = client.models.generate_content(
            model=self.model_name,
            contents=[
                prompt,
                types.Part.from_bytes(data=wav_bytes, mime_type="audio/wav"),
            ],
            config={"temperature": 0.0},
        )
        return response.text or ""

    def _call_gemini_file(self, file_path: str, prompt: str) -> str:
        from google import genai

        api_key = get_gemini_api_key()
        if not api_key:
            raise FileTranscriptionError("No Gemini API key configured.")

        client = genai.Client(api_key=api_key)
        uploaded = client.files.upload(file=file_path)
        response = client.models.generate_content(
            model=self.model_name,
            contents=[prompt, uploaded],
            config={"temperature": 0.0},
        )
        return response.text or ""

    # -- OpenAI backend --
    def _call_openai(
        self,
        wav_bytes: bytes,
        initial_prompt: Optional[str],
        allowed_languages: Optional[list[str]],
    ) -> str:
        from openai import OpenAI

        api_key = get_openai_api_key()
        if not api_key:
            raise RuntimeError("No OpenAI API key configured.")

        client = OpenAI(api_key=api_key, timeout=_CLOUD_STT_TIMEOUT_SECONDS)

        buf = io.BytesIO(wav_bytes)
        buf.name = "audio.wav"

        kwargs: dict = {"model": self.model_name, "file": buf}
        prompt = _build_openai_prompt(self.model_name, initial_prompt)
        if prompt:
            kwargs["prompt"] = prompt
        if allowed_languages and len(allowed_languages) == 1:
            kwargs["language"] = allowed_languages[0]

        response = client.audio.transcriptions.create(**kwargs)
        return getattr(response, "text", "") or ""

    def _call_openai_file(
        self,
        file_path: str,
        initial_prompt: Optional[str],
        allowed_languages: Optional[list[str]],
    ) -> str:
        from openai import OpenAI

        api_key = get_openai_api_key()
        if not api_key:
            raise FileTranscriptionError("No OpenAI API key configured.")

        client = OpenAI(api_key=api_key, timeout=_CLOUD_STT_FILE_TIMEOUT_SECONDS)

        kwargs: dict = {"model": self.model_name}
        prompt = _build_openai_prompt(self.model_name, initial_prompt)
        if prompt:
            kwargs["prompt"] = prompt
        if allowed_languages and len(allowed_languages) == 1:
            kwargs["language"] = allowed_languages[0]

        with open(file_path, "rb") as f:
            response = client.audio.transcriptions.create(file=f, **kwargs)
        return getattr(response, "text", "") or ""
