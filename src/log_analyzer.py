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


def generate_terms_hint_from_history(max_en_terms: int = 15, max_ru_phrases: int = 5) -> str:
    """Generate a hint sentence with frequent technical terms and phrases from phrase history."""
    history_path = get_phrases_file_path()
    if not history_path.exists():
        log_info("Phrase history file does not exist; cannot generate terms hint.")
        return ""

    try:
        with history_path.open("r", encoding="utf-8") as f:
            # Read the last 1000 phrases to get enough context
            lines = deque(f, maxlen=1000)
    except OSError as exc:
        log_error(f"Failed to read phrase history for terms hint: {exc}")
        return ""

    # Extract text parts from "Timestamp\tText" lines
    texts = []
    for line in lines:
        parts = line.strip().split("\t", 1)
        if len(parts) == 2:
            texts.append(parts[1])

    if not texts:
        log_info("No transcribed phrases found in history.")
        return ""

    en_counts = _collect_english_terms(texts)
    ru_counts = _collect_russian_ngrams(texts)

    top_en_terms = [term for term, _ in en_counts.most_common(max_en_terms)]
    top_ru_phrases = [phrase for phrase, count in ru_counts.most_common(max_ru_phrases) if count > 1]

    if not top_en_terms and not top_ru_phrases:
        log_info("No suitable terms or phrases found in history.")
        return ""

    parts = ["Например, я часто использую"]
    
    if top_en_terms:
        parts.append("англоязычные термины: " + ", ".join(top_en_terms) + ".")
    
    if top_ru_phrases:
        parts.append("А также русские выражения: " + ", ".join(top_ru_phrases) + ".")

    sentence = " ".join(parts)
    return sentence

