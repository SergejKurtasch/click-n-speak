import re
from collections import Counter, defaultdict, deque
from datetime import datetime
from typing import Callable, Iterable

from .utils import (
    canonical_term_key,
    canonicalize_term,
    existing_terms_union_for_script,
    get_phrases_file_path,
    log_error,
    log_info,
    skipped_phrases_merge_for_script,
)


# Must start with a letter; allows letters, digits, +, #, ., _, - afterwards.
# Minimum effective length: 2 chars (one letter + at least one more character).
_TERM_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9+#._-]+")
_RUS_WORD_PATTERN = re.compile(r"[А-Яа-яЁё]+")

# Russian function words that produce low-value bigrams when combined with any word.
_RUS_FUNCTION_WORDS: frozenset[str] = frozenset({
    # Personal pronouns — all cases
    "я", "мне", "меня", "мной", "мною",
    "ты", "тебя", "тебе", "тобой", "тобою",
    "он", "ему", "его", "него", "ним", "нём",
    "она", "ей", "её", "неё", "ею", "нею",
    "оно",
    "мы", "нас", "нам", "нами",
    "вы", "вас", "вам", "вами",
    "они", "их", "им", "ими", "них", "ними",
    "себя", "себе", "собой", "собою",
    # Demonstratives
    "это", "этот", "эта", "эти", "этих", "этому", "этим", "этими", "этой", "этого",
    "тот", "та", "то", "те", "тех", "тому", "тем", "теми", "той", "того",
    "там", "тут", "туда", "сюда", "здесь",
    # Relative / interrogative pronouns
    "который", "которая", "которое", "которые",
    "которого", "которой", "которых", "которому", "которым", "которыми",
    "кто", "что", "кого", "чего", "кому", "чему", "кем", "чем",
    "где", "куда", "откуда", "когда", "зачем", "почему",
    # Copula / auxiliary
    "есть", "нет", "был", "была", "было", "были", "быть",
    "будет", "будут", "буду", "будем", "будете", "будешь",
    # Modal verbs
    "надо", "нужно", "можно", "нельзя",
    "может", "могут", "могу", "можем", "можете", "можешь",
    "должен", "должна", "должно", "должны",
    "хочет", "хочу", "хотим", "хотите", "хочешь", "хотят",
    "хотел", "хотела", "хотели",
    # Conjunctions / particles / connectives
    "и", "а", "но", "или", "ни", "либо",
    "что", "чтобы", "если", "когда", "хотя", "потому", "поэтому",
    "однако", "зато", "причём", "притом",
    "да", "как", "так", "вот", "ну", "ли", "же", "бы",
    "даже", "именно", "ведь", "лишь", "именно", "всё",
    # Common adverbs of degree / time
    "очень", "просто", "только", "уже", "ещё", "еще", "тоже", "почти",
    "всегда", "никогда", "иногда", "сейчас", "теперь", "потом", "тогда",
    "сначала", "наконец", "сразу", "вдруг", "опять", "снова",
    # Prepositions
    "для", "при", "про", "без", "над", "под", "перед", "после", "через",
    "между", "около", "вместо", "кроме", "против", "вдоль", "среди",
    "из", "от", "до", "по", "за", "на", "в", "к", "со", "об",
    # Language-echo words: Whisper often echoes initial_prompt language hints
    "язык", "языке", "языка", "языком", "языки", "языков",
    "русский", "русского", "русскому", "русском",
    "английский", "английском", "английского", "английскому",
    # Generic high-frequency verbs producing low-value filler
    "сделал", "сделала", "сделали", "делает", "делал", "делала",
    "говорит", "говорят", "говорил", "говорила", "говорили",
    "сказал", "сказала", "сказали", "идёт", "идет", "стал", "стала", "стали",
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
    Returns 3 (include-by-default) when the tokenizer is unavailable or returns 0
    (which happens when mlx_whisper is mocked in tests or the encoder is a stub).
    """
    cached = _token_count_cache.get(word)
    if cached is not None:
        return cached
    enc = _get_whisper_encoder()
    if enc is not None:
        raw = len(enc.encode(" " + word))
        count = raw if raw > 0 else 3  # 0 from a mock/stub → treat as "include"
    else:
        count = 3  # fallback that passes the `< 3` bigram filter instead of failing it
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

# Public aliases for reuse in other analyzers.
TERM_PATTERN = _TERM_PATTERN
TERM_STOPLIST = _TERM_STOPLIST
RUS_FUNCTION_WORDS = _RUS_FUNCTION_WORDS


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
    term_has_correction_signal: Callable[[str], bool] | None = None,
) -> list[tuple[str, int]]:
    """Extract Latin-script tokens appearing in >= 2 distinct sessions (unless bypassed).

    Groups case variants (GitHub/github) and keeps the most-frequent spelling.
    Applies _TERM_STOPLIST, path/URL fragment filter (> 1 dot or slash), and blacklist.
    Returns [(best_variant, total_count), ...] sorted by total_count descending.
    """
    variant_counts: Counter = Counter()
    term_sessions: dict[str, set[int]] = defaultdict(set)

    for (_, text), sid in zip(records, session_ids):
        seen_lower_in_record: set[str] = set()
        for match in _TERM_PATTERN.finditer(text):
            term = canonicalize_term(match.group(0))
            if not term:
                continue
            lower = canonical_term_key(term)
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
        has_correction = bool(term_has_correction_signal and term_has_correction_signal(lower))
        if not has_correction and len(term_sessions[lower]) < 2:
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

    Length prefiltration avoids calling _levenshtein for pairs whose length
    difference already guarantees distance > 2, giving a practical speedup of
    10-100× over the naive O(n²) approach for large candidate sets.
    """
    removed: set[int] = set()
    for i in range(len(candidates)):
        if i in removed:
            continue
        term_i = candidates[i][0].lower()
        len_i = len(term_i)
        for j in range(i + 1, len(candidates)):
            if j in removed:
                continue
            term_j = candidates[j][0].lower()
            # _levenshtein already returns 3 early on len diff > 2, but we skip the
            # function call overhead entirely for clearly distant pairs.
            if abs(len_i - len(term_j)) > 2:
                continue
            if _levenshtein(term_i, term_j) <= 1:
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
            term = canonicalize_term(match.group(0))
            if not term:
                continue
            lower = canonical_term_key(term)
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
    lookback: int = 300,
    min_count: dict[str, int] | int | None = None,
    existing_lower_by_lang: dict[str, set[str]] | None = None,
    skipped_lower_by_lang: dict[str, dict[str, int]] | None = None,
    current_phrase_count: int = 0,
    cooldown_phrases: int = 150,
    max_per_lang: int = 15,
    term_has_correction_signal: Callable[[str], bool] | None = None,
) -> dict[str, list[dict[str, object]]]:
    """Analyze phrase history and return vocabulary candidates for user_terms.

    Latin-script tokens → "latin" bucket; Cyrillic bigrams → "cyrillic" bucket.
    existing_lower_by_lang / skipped_lower_by_lang use ISO language codes (ru, en, de, …);
    terms are filtered per script via union across matching languages.
    Returns {"latin": [...], "cyrillic": [...]}, sorted by count descending.
    """
    if min_count is None:
        min_count_dict = {"latin": 5, "cyrillic": 8}
    elif isinstance(min_count, int):
        min_count_dict = {"latin": min_count, "cyrillic": min_count}
    else:
        min_count_dict = dict(min_count)
    latin_min = int(min_count_dict.get("latin", 5))
    cyrillic_min = int(min_count_dict.get("cyrillic", 8))

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

    # Latin-script tokens — session-based filter (≥2 distinct sessions) unless bypassed.
    session_ids = _assign_session_ids(records)
    latin_raw = _collect_english_terms(
        records,
        session_ids,
        term_has_correction_signal=term_has_correction_signal,
    )
    latin_raw = _filter_near_duplicates(latin_raw)
    existing_latin = existing_terms_union_for_script(existing, "latin")
    skipped_latin = skipped_phrases_merge_for_script(skipped, "latin")

    latin_candidates: list[dict] = []
    for term, count in latin_raw:
        if count < latin_min:
            continue  # sorted by score not count, so low-count items can appear anywhere
        lower = canonical_term_key(term)
        if lower in existing_latin:
            continue
        skipped_at = skipped_latin.get(lower, -1)
        if 0 <= skipped_at and current_phrase_count - skipped_at < cooldown_phrases:
            continue
        latin_candidates.append({"term": term, "count": count})
        if len(latin_candidates) >= max_per_lang:
            break

    # Cyrillic bigrams — sort by token-weighted score, not raw count
    cyrillic_counts = _collect_russian_bigrams(texts)
    existing_cyrillic = existing_terms_union_for_script(existing, "cyrillic")
    skipped_cyrillic = skipped_phrases_merge_for_script(skipped, "cyrillic")

    cyrillic_candidates: list[dict] = []
    for phrase, count in sorted(
        cyrillic_counts.items(), key=lambda kv: -(kv[1] * _ru_whisper_bonus(kv[0]))
    ):
        if count < cyrillic_min:
            continue
        lower = canonical_term_key(phrase)
        if lower in existing_cyrillic:
            continue
        skipped_at = skipped_cyrillic.get(lower, -1)
        if 0 <= skipped_at and current_phrase_count - skipped_at < cooldown_phrases:
            continue
        cyrillic_candidates.append({"term": phrase, "count": count})
        if len(cyrillic_candidates) >= max_per_lang:
            break

    result: dict[str, list[dict]] = {}
    if latin_candidates:
        result["latin"] = latin_candidates
    if cyrillic_candidates:
        result["cyrillic"] = cyrillic_candidates
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
