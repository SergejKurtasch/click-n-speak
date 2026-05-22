"""
dataset_logger.py — Append-only JSONL logger for transcription dataset collection.

Saves triplets of (raw_whisper, ai_edited, user_final) text to a local file
so the data can later be used for fine-tuning or quality analysis.
"""

import datetime
import json
import os
import re
from typing import Optional

from .utils import canonical_term_key, log_error, log_info

# Default path for the dataset file (hidden file in user home)
_DEFAULT_DATASET_PATH = os.path.expanduser("~/.clicknspeak_dataset.jsonl")

_WORD_RE = re.compile(r"[\w\-.+#]+", re.UNICODE)


def _find_terms(text: str, terms: list[str]) -> list[str]:
    """Return canonical keys of user terms found in text (case-insensitive).

    Single-word terms use token-set matching; multi-word phrases use substring
    search on the lowercased text so "machine learning" matches correctly.
    """
    if not text or not terms:
        return []
    tokens = {canonical_term_key(t) for t in _WORD_RE.findall(text)}
    text_lower = text.lower()
    found: set[str] = set()
    for term in terms:
        key = canonical_term_key(term)
        if not key:
            continue
        if " " in key:
            if key in text_lower:
                found.add(key)
        else:
            if key in tokens:
                found.add(key)
    return sorted(found)


def append_to_dataset(
    raw_text: str,
    ai_text: Optional[str],
    user_final_text: str,
    ai_status: Optional[str] = None,
    dataset_path: str = _DEFAULT_DATASET_PATH,
    *,
    lang: Optional[str] = None,
    user_terms_for_lang: Optional[list[str]] = None,
    prompt_hash: Optional[str] = None,
) -> None:
    """Append a single transcription record to the JSONL dataset file.

    Args:
        raw_text: Original text from Whisper (before AI editing).
        ai_text: Text after AI Editor refinement (None if AI Editor was off or skipped).
        user_final_text: Text the user actually confirmed/sent after editing.
        ai_status: One of AiEditor.REFINE_STATUS_* or None (AI disabled / not run).
        dataset_path: Path to the JSONL file.
        lang: Detected transcription language (ISO 639-1).
        user_terms_for_lang: Active user_terms for the detected language (term strings).
        prompt_hash: md5[:12] of initial_prompt at transcription time.
    """
    terms = user_terms_for_lang or []
    record = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "raw_whisper": raw_text,
        "ai_edited": ai_text,
        "ai_status": ai_status,
        "user_final": user_final_text,
        "lang": lang,
        "prompt_hash": prompt_hash,
        "vocab_terms_in_raw": _find_terms(raw_text, terms),
        "vocab_terms_in_final": _find_terms(user_final_text, terms),
    }

    try:
        with open(dataset_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        log_info(
            f"Dataset record saved: raw={len(raw_text)} chars, "
            f"ai={'off' if ai_text is None else f'{len(ai_text)} chars'}, "
            f"user={len(user_final_text)} chars"
        )
    except Exception as e:
        log_error(f"Failed to write dataset record: {e}")
