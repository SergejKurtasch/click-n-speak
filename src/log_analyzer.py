import re
from collections import Counter
from typing import Iterable, List

from .utils import get_log_file_path, log_error, log_info


PARTIAL_PREFIX = "Partial Transcription:"


def _extract_partial_text(line: str) -> str:
    """Extracts the transcription text from a log line, if present."""
    if PARTIAL_PREFIX not in line:
        return ""
    try:
        _, after_level, = line.split(" - INFO - ", maxsplit=1)
    except ValueError:
        # Fallback: split just on prefix
        idx = line.find(PARTIAL_PREFIX)
        if idx == -1:
            return ""
        return line[idx + len(PARTIAL_PREFIX) :].strip()
    idx = after_level.find(PARTIAL_PREFIX)
    if idx == -1:
        return ""
    return after_level[idx + len(PARTIAL_PREFIX) :].strip()


def _iter_partial_texts(lines: Iterable[str]) -> Iterable[str]:
    """Yields all partial transcription texts from log lines."""
    for line in lines:
        text = _extract_partial_text(line)
        if text:
            yield text


_TERM_PATTERN = re.compile(r"[A-Za-z0-9_/.\-]+")


def _collect_terms(texts: Iterable[str]) -> Counter:
    """Collects term frequencies from transcribed texts."""
    counter: Counter = Counter()
    for text in texts:
        for match in _TERM_PATTERN.finditer(text):
            term = match.group(0)
            # Skip very short tokens
            if len(term) < 2:
                continue
            # Require at least one alphabetic character to avoid pure numbers
            if not re.search(r"[A-Za-z]", term):
                continue
            counter[term] += 1
    return counter


def generate_terms_hint_from_log(max_terms: int = 20) -> str:
    """Generate a short Russian sentence with frequent technical terms from the log."""
    log_path = get_log_file_path()
    if not log_path.exists():
        log_info("Log file does not exist; cannot generate terms hint.")
        return ""

    try:
        with log_path.open("r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as exc:
        log_error(f"Failed to read log file for terms hint: {exc}")
        return ""

    texts = list(_iter_partial_texts(lines))
    if not texts:
        log_info("No partial transcriptions found in log for terms hint.")
        return ""

    term_counts = _collect_terms(texts)
    if not term_counts:
        log_info("No suitable technical terms found in log for terms hint.")
        return ""

    # Take most frequent terms
    top_terms: List[str] = [term for term, _ in term_counts.most_common(max_terms)]
    if not top_terms:
        return ""

    # Build a simple Russian sentence embedding these terms
    # Limit length roughly by cutting the list if it becomes too long
    joined = ", ".join(top_terms)
    sentence = (
        "Например, я часто говорю про следующие модели, библиотеки и параметры: "
        f"{joined}."
    )
    return sentence

