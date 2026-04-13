"""
dataset_logger.py — Append-only JSONL logger for transcription dataset collection.

Saves triplets of (raw_whisper, ai_edited, user_final) text to a local file
so the data can later be used for fine-tuning or quality analysis.
"""

import json
import os
import time
from typing import Optional

from .utils import log_error, log_info

# Default path for the dataset file (hidden file in user home)
_DEFAULT_DATASET_PATH = os.path.expanduser("~/.clicknspeak_dataset.jsonl")


def append_to_dataset(
    raw_text: str,
    ai_text: Optional[str],
    user_final_text: str,
    dataset_path: str = _DEFAULT_DATASET_PATH,
) -> None:
    """Append a single transcription record to the JSONL dataset file.

    Args:
        raw_text: Original text from Whisper (before AI editing).
        ai_text: Text after AI Editor refinement (None if AI Editor was off).
        user_final_text: Text the user actually confirmed/sent after editing.
        dataset_path: Path to the JSONL file.
    """
    record = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "raw_whisper": raw_text,
        "ai_edited": ai_text,
        "user_final": user_final_text,
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
