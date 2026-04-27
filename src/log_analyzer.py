import re
from collections import Counter, defaultdict, deque
from datetime import datetime
from typing import Iterable

from .utils import get_phrases_file_path, log_error, log_info


# Must start with a letter; allows letters, digits, +, #, ., _, - afterwards.
# Minimum effective length: 2 chars (one letter + at least one more character).
_TERM_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9+#._-]+")
_RUS_WORD_PATTERN = re.compile(r"[А-Яа-яЁё]+")

# Russian function words that produce low-value bigrams when combined with any word.
_RUS_FUNCTION_WORDS: frozenset[str] = frozenset({
    # Pronouns / demonstratives
    "это", "этот", "эта", "том", "там", "тут", "тот",
    # Copula / modal
    "есть", "нет", "был", "была", "было", "быть", "надо", "нужно", "можно", "нельзя",
    # Particles / connectives
    "да", "как", "так", "вот", "ну", "ли", "же",
    # Common adverbs of degree / time
    "очень", "просто", "только", "уже", "ещё", "еще", "тоже", "почти", "всегда",
    # Prepositions — commonly anchor generic sentence fragments, not domain terms
    "для", "при", "про", "без", "над", "под", "перед", "после", "через",
    "между", "около", "вместо", "кроме", "против", "вдоль", "среди",
    # Language-echo words: Whisper often echoes initial_prompt language hints
    # (e.g. "Русский язык." → "русский язык" bigram appears in transcriptions)
    "язык", "языке", "языка", "языком", "языки", "языков",
    "русский", "русского", "русскому", "русском",
    "английский", "английском", "английского", "английскому",
    # Generic verbs that produce low-value filler bigrams
    "сделал", "сделала", "сделали", "делает", "делал", "делала",
})

# Lazy-loaded Whisper BPE encoder and per-word token count cache.
_whisper_enc = None
_whisper_enc_tried: bool = False
_token_count_cache: dict[str, int] = {}


def _get_whisper_encoder() -> object | None:
    """Lazy-load the Whisper multilingual BPE encoder; returns None if unavailable."""
    global _whisper_enc, _whisper_enc_tried
    if _whisper_enc_tried:
        return _whisper_enc
    _whisper_enc_tried = True
    try:
        from mlx_whisper.tokenizer import get_tokenizer  # noqa: PLC0415
        _whisper_enc = get_tokenizer(multilingual=True, language="en").encoding
    except Exception as exc:
        log_error(f"Whisper tokenizer unavailable, falling back to raw counts: {exc}")
    return _whisper_enc


def _whisper_token_count(word: str) -> int:
    """Return how many BPE tokens Whisper uses to encode *word*.

    More tokens → rarer in Whisper's training data → higher prompt priority.
    Returns 2 (neutral) when the tokenizer is unavailable.
    """
    cached = _token_count_cache.get(word)
    if cached is not None:
        return cached
    enc = _get_whisper_encoder()
    count = len(enc.encode(" " + word)) if enc is not None else 2
    _token_count_cache[word] = count
    return count


def _en_whisper_bonus(term: str) -> float:
    """Score multiplier for an English term based on its Whisper BPE token count."""
    n = _whisper_token_count(term)
    if n >= 4:
        return 4.0
    if n >= 3:
        return 2.5
    if n >= 2:
        return 1.5
    return 1.0  # 1 token = Whisper knows this word; no boost


def _ru_whisper_bonus(phrase: str) -> float:
    """Score multiplier for a Russian bigram based on the rarer word's token count."""
    words = phrase.split()
    max_n = max((_whisper_token_count(w) for w in words), default=1)
    if max_n >= 4:
        return 4.0
    if max_n >= 3:
        return 2.5
    if max_n >= 2:
        return 1.5
    return 1.0

# Consecutive-record gap (seconds) that marks the start of a new session.
_SESSION_GAP_SECONDS = 60

# Common English function words and URL-fragment tokens to always skip.
_TERM_STOPLIST: frozenset[str] = frozenset({
    "http", "https", "www", "com", "org", "net", "edu", "gov",
    "the", "and", "for", "are", "but", "not", "you", "all",
    "can", "had", "her", "was", "one", "our", "out", "day",
    "get", "has", "him", "his", "how", "man", "new", "now",
    "old", "see", "two", "way", "who", "its", "let", "put",
    "say", "she", "too", "use",
})


def _levenshtein(a: str, b: str) -> int:
    """Return edit distance between two strings; returns 3 early when gap > 2."""
    if abs(len(a) - len(b)) > 2:
        return 3
    if len(a) < len(b):
        a, b = b, a
    la, lb = len(a), len(b)
    row = list(range(lb + 1))
    for i in range(1, la + 1):
        new_row = [i]
        for j in range(1, lb + 1):
            new_row.append(min(
                row[j] + 1,
                new_row[j - 1] + 1,
                row[j - 1] + (0 if a[i - 1] == b[j - 1] else 1),
            ))
        row = new_row
    return row[lb]


def _parse_history_lines(lines: Iterable[str]) -> list[tuple[datetime, str]]:
    """Parse TSV history lines into (timestamp, text) pairs; skips malformed lines."""
    records: list[tuple[datetime, str]] = []
    for line in lines:
        parts = line.strip().split("\t", 1)
        if len(parts) != 2:
            continue
        try:
            ts = datetime.strptime(parts[0], "%Y-%m-%dT%H:%M:%S")
            records.append((ts, parts[1]))
        except ValueError:
            continue
    return records


def _assign_session_ids(records: list[tuple[datetime, str]]) -> list[int]:
    """Assign a monotonically increasing session ID to each record.

    A new session begins when the gap to the previous record is >= _SESSION_GAP_SECONDS.
    """
    if not records:
        return []
    ids = [0]
    sid = 0
    for i in range(1, len(records)):
        gap = (records[i][0] - records[i - 1][0]).total_seconds()
        if gap >= _SESSION_GAP_SECONDS:
            sid += 1
        ids.append(sid)
    return ids


def _collect_english_terms(
    records: list[tuple[datetime, str]],
    session_ids: list[int],
    blacklist: frozenset[str] = frozenset(),
) -> list[tuple[str, int]]:
    """Extract English terms appearing in >= 2 distinct sessions.

    Groups case variants (GitHub/github) and keeps the most-frequent spelling.
    Applies _TERM_STOPLIST, path/URL fragment filter (> 1 dot or slash), and blacklist.
    Returns [(best_variant, total_count), ...] sorted by total_count descending.
    """
    variant_counts: Counter = Counter()
    term_sessions: dict[str, set[int]] = defaultdict(set)

    for (_, text), sid in zip(records, session_ids):
        seen_lower_in_record: set[str] = set()
        for match in _TERM_PATTERN.finditer(text):
            term = match.group(0)
            lower = term.lower()
            if lower in _TERM_STOPLIST or lower in blacklist:
                continue
            if term.count("/") > 1 or term.count(".") > 1:
                continue
            variant_counts[term] += 1
            if lower not in seen_lower_in_record:
                term_sessions[lower].add(sid)
                seen_lower_in_record.add(lower)

    # Group by lowercase; sum counts; pick best-spelling variant; filter by session count.
    lower_to_variants: dict[str, list[str]] = defaultdict(list)
    for variant in variant_counts:
        lower_to_variants[variant.lower()].append(variant)

    candidates: list[tuple[str, int]] = []
    for lower, variants in lower_to_variants.items():
        if len(term_sessions[lower]) < 2:
            continue
        best = max(variants, key=lambda v: variant_counts[v])
        total = sum(variant_counts[v] for v in variants)
        candidates.append((best, total))

    candidates.sort(key=lambda x: -(x[1] * _en_whisper_bonus(x[0])))
    return candidates


def _filter_near_duplicates(
    candidates: list[tuple[str, int]],
) -> list[tuple[str, int]]:
    """Remove near-duplicate terms (Levenshtein distance <= 1), keeping the more frequent one.

    Candidates must be pre-sorted by count descending so that the first of a
    near-duplicate pair is always the more frequent one.
    """
    removed: set[int] = set()
    for i in range(len(candidates)):
        if i in removed:
            continue
        for j in range(i + 1, len(candidates)):
            if j in removed:
                continue
            if _levenshtein(candidates[i][0].lower(), candidates[j][0].lower()) <= 1:
                removed.add(j)
    return [c for idx, c in enumerate(candidates) if idx not in removed]


def _collect_raw_english_counts(
    records: list[tuple[datetime, str]],
    blacklist: frozenset[str] = frozenset(),
) -> list[tuple[str, int]]:
    """Like _collect_english_terms but without the session requirement.

    Used for Etap-3 candidate analysis (pure count in window, not cross-session).
    Returns [(best_variant, total_count), ...] sorted descending.
    """
    variant_counts: Counter = Counter()

    for (_, text) in records:
        for match in _TERM_PATTERN.finditer(text):
            term = match.group(0)
            lower = term.lower()
            if lower in _TERM_STOPLIST or lower in blacklist:
                continue
            if term.count("/") > 1 or term.count(".") > 1:
                continue
            variant_counts[term] += 1

    if not variant_counts:
        return []

    lower_to_variants: dict[str, list[str]] = defaultdict(list)
    for variant in variant_counts:
        lower_to_variants[variant.lower()].append(variant)

    candidates: list[tuple[str, int]] = []
    for lower, variants in lower_to_variants.items():
        best = max(variants, key=lambda v: variant_counts[v])
        total = sum(variant_counts[v] for v in variants)
        candidates.append((best, total))

    candidates.sort(key=lambda x: -(x[1] * _en_whisper_bonus(x[0])))
    return candidates


def get_prompt_candidates(
    lookback: int = 100,
    min_count: int = 5,
    existing_lower_by_lang: dict[str, set[str]] | None = None,
    skipped_lower_by_lang: dict[str, dict[str, int]] | None = None,
    current_phrase_count: int = 0,
    cooldown_phrases: int = 100,
    max_per_lang: int = 20,
) -> dict[str, list[dict[str, object]]]:
    """Analyze phrase history and return vocabulary candidates for user_terms.

    English tokens → "en" bucket; Russian bigrams → "ru" bucket.
    Excludes terms in existing_lower_by_lang and those within cooldown window.
    Returns {"en": [{"term": "PCA", "count": 12}, ...], "ru": [...]},
    each list sorted by count descending and capped at max_per_lang.
    """
    history_path = get_phrases_file_path()
    if not history_path.exists():
        return {}

    try:
        with history_path.open("r", encoding="utf-8") as f:
            raw_lines = deque(f, maxlen=lookback)
    except OSError as exc:
        log_error(f"Failed to read phrase history for candidate analysis: {exc}")
        return {}

    records = _parse_history_lines(raw_lines)
    if not records:
        return {}

    existing = existing_lower_by_lang or {}
    skipped = skipped_lower_by_lang or {}
    texts = [text for _, text in records]

    # English candidates — session-based filter (≥2 distinct sessions) to
    # suppress hallucinations that Whisper repeats within one session burst.
    session_ids = _assign_session_ids(records)
    en_raw = _collect_english_terms(records, session_ids)
    en_raw = _filter_near_duplicates(en_raw)
    existing_en = existing.get("en", set())
    skipped_en = skipped.get("en", {})

    en_candidates: list[dict] = []
    for term, count in en_raw:
        if count < min_count:
            continue  # sorted by score not count, so low-count items can appear anywhere
        lower = term.lower()
        if lower in existing_en:
            continue
        skipped_at = skipped_en.get(lower, -1)
        if 0 <= skipped_at and current_phrase_count - skipped_at < cooldown_phrases:
            continue
        en_candidates.append({"term": term, "count": count})
        if len(en_candidates) >= max_per_lang:
            break

    # Russian bigrams — sort by token-weighted score, not raw count
    ru_counts = _collect_russian_bigrams(texts)
    existing_ru = existing.get("ru", set())
    skipped_ru = skipped.get("ru", {})

    ru_candidates: list[dict] = []
    for phrase, count in sorted(ru_counts.items(), key=lambda kv: -(kv[1] * _ru_whisper_bonus(kv[0]))):
        if count < min_count:
            continue
        lower = phrase.lower()
        if lower in existing_ru:
            continue
        skipped_at = skipped_ru.get(lower, -1)
        if 0 <= skipped_at and current_phrase_count - skipped_at < cooldown_phrases:
            continue
        ru_candidates.append({"term": phrase, "count": count})
        if len(ru_candidates) >= max_per_lang:
            break

    result: dict[str, list[dict]] = {}
    if en_candidates:
        result["en"] = en_candidates
    if ru_candidates:
        result["ru"] = ru_candidates
    return result


def _collect_russian_bigrams(texts: Iterable[str]) -> Counter:
    """Collect Russian bigram frequencies, pre-filtered for prompt relevance.

    Drops bigrams where either word is a function word, where both words are
    single Whisper BPE tokens (Whisper already knows them; no prompt value),
    or where the two words are identical (Whisper word-repetition hallucination).
    Also drops reverse-duplicate pairs: if both "A B" and "B A" appear with
    similar counts (ratio ≥ 0.4) they are likely hallucinated and both are removed.
    """
    counter: Counter = Counter()
    for text in texts:
        words = _RUS_WORD_PATTERN.findall(text)
        words = [w.lower() for w in words if len(w) >= 3]
        for i in range(len(words) - 1):
            w1, w2 = words[i], words[i + 1]
            if w1 == w2:
                continue  # word-repetition hallucination (e.g. "включить включить")
            if w1 in _RUS_FUNCTION_WORDS or w2 in _RUS_FUNCTION_WORDS:
                continue
            if max(_whisper_token_count(w1), _whisper_token_count(w2)) < 3:
                continue
            counter[f"{w1} {w2}"] += 1

    # Remove reverse-duplicate pairs — a sign of Whisper generating the same
    # hallucinated phrase in inconsistent word order across recordings.
    to_remove: set[str] = set()
    for bigram, count in list(counter.items()):
        w1, w2 = bigram.split(" ", 1)
        reverse = f"{w2} {w1}"
        rev_count = counter.get(reverse, 0)
        if rev_count > 0 and min(count, rev_count) / max(count, rev_count) >= 0.4:
            to_remove.add(bigram)
            to_remove.add(reverse)
    for bigram in to_remove:
        del counter[bigram]

    return counter


def get_frequent_terms(
    max_en_terms: int = 20,
    max_ru_phrases: int = 5,
    lookback: int = 1000,
    blacklist: frozenset[str] = frozenset(),
) -> tuple[list[str], list[str]]:
    """Return (en_terms, ru_bigrams) extracted from the last *lookback* phrases.

    en_terms   — most common English technical tokens appearing in >= 2 distinct sessions,
                 deduplicated by case and near-spelling (Levenshtein <= 1).
    ru_bigrams — most common Russian bigrams with frequency >= 3.
    blacklist  — lowercase terms the user explicitly removed; always excluded from en_terms.
    """
    history_path = get_phrases_file_path()
    if not history_path.exists():
        return [], []

    try:
        with history_path.open("r", encoding="utf-8") as f:
            raw_lines = deque(f, maxlen=lookback)
    except OSError as exc:
        log_error(f"Failed to read phrase history: {exc}")
        return [], []

    records = _parse_history_lines(raw_lines)
    if not records:
        return [], []

    session_ids = _assign_session_ids(records)
    texts = [text for _, text in records]

    candidates = _collect_english_terms(records, session_ids, blacklist=blacklist)
    candidates = _filter_near_duplicates(candidates)
    top_en = [term for term, _ in candidates[:max_en_terms]]

    ru_counts = _collect_russian_bigrams(texts)
    top_ru = [
        phrase
        for phrase, count in sorted(
            ru_counts.items(), key=lambda kv: -(kv[1] * _ru_whisper_bonus(kv[0]))
        )[:max_ru_phrases]
        if count >= 3
    ]

    return top_en, top_ru
