"""Persist and retrieve full phrases from recognition sessions (one phrase per hotkey start–stop)."""

from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple

from .utils import get_phrases_file_path, log_error, log_info

# In-memory phrase count. None = not yet loaded from disk.
# Incremented on every successful append so count_phrases() avoids an O(n) file scan
# on each transcription completion (called in the injection hotpath).
_phrase_count: Optional[int] = None


def append_phrase(text: str) -> None:
    """Append a single phrase with timestamp to the history file. Normalizes text (strip, newline to space)."""
    global _phrase_count
    normalized = text.strip().replace("\n", " ")
    if not normalized:
        return
    path = get_phrases_file_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
        line = f"{ts}\t{normalized}\n"
        with path.open("a", encoding="utf-8") as f:
            f.write(line)
        # Update cache after a confirmed write so the next count_phrases() returns
        # immediately without a file scan.
        if _phrase_count is None:
            _phrase_count = count_phrases()  # lazy init from disk
        else:
            _phrase_count += 1
    except OSError as e:
        log_error(f"Failed to append phrase to {path}: {e}")


def count_phrases() -> int:
    """Return total number of phrases stored in the history file.

    Returns the in-memory cached value when available (O(1)); otherwise reads
    the file once and caches the result.
    """
    global _phrase_count
    if _phrase_count is not None:
        return _phrase_count
    path = get_phrases_file_path()
    if not path.exists():
        _phrase_count = 0
        return 0
    try:
        with path.open("r", encoding="utf-8") as f:
            _phrase_count = sum(1 for line in f if line.strip())
    except OSError:
        _phrase_count = 0
    return _phrase_count


def get_last_phrases(n: int) -> List[Tuple[str, str]]:
    """Return up to n last phrases as (timestamp_str, text), oldest first."""
    path = get_phrases_file_path()
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as f:
            lines = [line.strip() for line in f.readlines() if line.strip()]
    except OSError as e:
        log_error(f"Failed to read phrase history from {path}: {e}")
        return []

    result: List[Tuple[str, str]] = []
    for line in lines[-n:]:
        parts = line.split("\t", 1)
        if len(parts) == 2:
            result.append((parts[0], parts[1]))
        else:
            log_info(f"Skipping malformed phrase history line: {line[:80]}...")
    return result
