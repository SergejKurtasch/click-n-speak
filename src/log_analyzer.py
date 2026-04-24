import re
from collections import Counter, deque
from typing import Iterable, List

from .utils import get_phrases_file_path, log_error, log_info


_TERM_PATTERN = re.compile(r"[A-Za-z0-9_/.\-]+")
_RUS_WORD_PATTERN = re.compile(r"[А-Яа-яЁё]+")


def _collect_english_terms(texts: Iterable[str]) -> Counter:
    """Collects english term frequencies from transcribed texts."""
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


def _collect_russian_ngrams(texts: Iterable[str]) -> Counter:
    """Collects Russian bigrams and trigrams from texts."""
    counter: Counter = Counter()
    for text in texts:
        # Find all Russian words
        words = _RUS_WORD_PATTERN.findall(text)
        # Lowercase and keep only words of length >= 3 to filter out short prepositions
        words = [w.lower() for w in words if len(w) >= 3]
        
        # Bigrams
        for i in range(len(words) - 1):
            counter[" ".join(words[i : i + 2])] += 1
            
        # Trigrams
        for i in range(len(words) - 2):
            counter[" ".join(words[i : i + 3])] += 1
            
    return counter


def get_frequent_terms(
    max_en_terms: int = 20,
    max_ru_phrases: int = 5,
    lookback: int = 1000,
) -> tuple[list[str], list[str]]:
    """Return (en_terms, ru_bigrams) extracted from the last *lookback* phrases.

    en_terms  — most common English technical tokens (length >= 2, contains a letter).
    ru_bigrams — most common Russian bigrams with frequency >= 2.
    """
    history_path = get_phrases_file_path()
    if not history_path.exists():
        return [], []

    try:
        with history_path.open("r", encoding="utf-8") as f:
            lines = deque(f, maxlen=lookback)
    except OSError as exc:
        log_error(f"Failed to read phrase history: {exc}")
        return [], []

    texts: list[str] = []
    for line in lines:
        parts = line.strip().split("\t", 1)
        if len(parts) == 2:
            texts.append(parts[1])

    if not texts:
        return [], []

    en_counts = _collect_english_terms(texts)
    ru_counts = _collect_russian_ngrams(texts)

    top_en = [term for term, _ in en_counts.most_common(max_en_terms)]
    top_ru = [phrase for phrase, count in ru_counts.most_common(max_ru_phrases) if count > 1]
    return top_en, top_ru


def generate_terms_hint_from_history(max_en_terms: int = 15, max_ru_phrases: int = 5) -> str:
    """Generate a human-readable hint sentence from phrase history (legacy helper)."""
    top_en, top_ru = get_frequent_terms(max_en_terms=max_en_terms, max_ru_phrases=max_ru_phrases)
    if not top_en and not top_ru:
        log_info("No suitable terms or phrases found in history.")
        return ""

    parts = ["Например, я часто использую"]
    if top_en:
        parts.append("англоязычные термины: " + ", ".join(top_en) + ".")
    if top_ru:
        parts.append("А также русские выражения: " + ", ".join(top_ru) + ".")
    return " ".join(parts)

