import json
import re
from datetime import datetime, timezone
from typing import Any

from .utils import (
    _term_is_active,
    _term_str,
    canonical_term_key,
    canonicalize_term,
    get_corrections_file_path,
    get_language_script,
    get_primary_language,
)

_KNOWN_TERMS_CAP = 50
_MISRECOGNITIONS_CAP = 30
_MISRECOGNITIONS_MIN_COUNT = 3
_REPLACEMENT_APPLY_CAP = 500


def _sanitize_term(text: str) -> str:
    """Keep prompt payload single-line and quote-safe."""
    cleaned = (text or "").replace("\n", " ").replace("\r", " ").replace('"', "'").strip()
    return canonicalize_term(" ".join(cleaned.split()))


def normalize_replacement_side(text: str) -> str:
    """Normalize one side of a user-defined replacement pair (UI / storage)."""
    return _sanitize_term(text)


def add_term_to_user_terms(config: dict, lang: str, term: str, source: str = "manual") -> bool:
    """Add a term to user_terms[lang] with case-insensitive dedupe.

    Mutates `config` in place, does not perform file I/O.
    Returns True only when a new term is inserted.
    """
    normalized_lang = str(lang or "").lower().strip()
    normalized_term = _sanitize_term(term)
    if not normalized_lang or not normalized_term:
        return False

    user_terms = dict(config.get("user_terms") or {})
    current_items = list(user_terms.get(normalized_lang, []))
    existing_lower = {canonical_term_key(_term_str(item)) for item in current_items if _term_str(item).strip()}
    if canonical_term_key(normalized_term) in existing_lower:
        return False

    schema_version = int(config.get("schema_version", 1) or 1)
    if schema_version >= 5:
        now_iso = datetime.now(timezone.utc).isoformat()
        safe_source = source if source in ("manual", "auto", "correction") else "manual"
        current_items.append(
            {
                "term": normalized_term,
                "source": safe_source,
                "added_at": now_iso,
                "last_seen": now_iso,
                "use_count": 0,
            }
        )
    else:
        current_items.append(normalized_term)

    user_terms[normalized_lang] = current_items
    config["user_terms"] = user_terms
    return True


def _term_priority(item: Any) -> tuple[int, int]:
    if isinstance(item, str):
        return (0, 0)
    source_rank = {"manual": 0, "correction": 1, "auto": 2}.get(item.get("source", "manual"), 3)
    use_count = int(item.get("use_count", 0) or 0)
    return (source_rank, -use_count)


def collect_known_terms(config: dict, languages: list[str] | None = None, cap: int = _KNOWN_TERMS_CAP) -> list[str]:
    """Collect active known terms for provided languages, sorted by priority."""
    user_terms = dict(config.get("user_terms") or {})
    if languages:
        target_langs = list(dict.fromkeys(languages))
    else:
        primary = get_primary_language(config)
        additional = list(config.get("additional_languages") or [])
        target_langs = [primary] + [lang for lang in additional if lang != primary]

    ordered_items: list[Any] = []
    for lang in target_langs:
        for item in user_terms.get(lang, []):
            if _term_is_active(item):
                ordered_items.append(item)

    ordered_items.sort(key=_term_priority)
    seen: set[str] = set()
    result: list[str] = []
    for item in ordered_items:
        sanitized = _sanitize_term(_term_str(item))
        if not sanitized:
            continue
        lower = canonical_term_key(sanitized)
        if lower in seen:
            continue
        seen.add(lower)
        result.append(sanitized)
        if len(result) >= cap:
            break
    return result


def manual_replacement_tuples(config: dict | None) -> list[tuple[str, str]]:
    """Sanitized manual pairs in config order with canonical dedupe."""
    if not config:
        return []
    out: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for item in config.get("manual_replacements") or []:
        if not isinstance(item, dict):
            continue
        left = _sanitize_term(str(item.get("from", "")))
        right = _sanitize_term(str(item.get("to", "")))
        if not left or not right:
            continue
        key = (canonical_term_key(left), canonical_term_key(right))
        if key in seen:
            continue
        seen.add(key)
        out.append((left, right))
    return out


def list_replacement_rows_for_ui(config: dict, languages: list[str] | None = None) -> list[dict[str, Any]]:
    """Build rows for ReplacementsPanel: manual pairs first, then auto from corrections.json."""
    scripts: set[str] = {"latin", "cyrillic"}
    if languages:
        scripts = {get_language_script(lang) for lang in languages}

    rows: list[dict[str, Any]] = []
    for item in config.get("manual_replacements") or []:
        if not isinstance(item, dict):
            continue
        left = _sanitize_term(str(item.get("from", "")))
        right = _sanitize_term(str(item.get("to", "")))
        if not left or not right:
            continue
        at = item.get("added_at")
        rows.append(
            {
                "source": "manual",
                "from": left,
                "to": right,
                "count": None,
                "bucket": None,
                "added_at": at if isinstance(at, str) and at.strip() else None,
            }
        )

    index = _load_corrections_index()
    replacement_pairs = index.get("replacement_pairs") or {}
    auto_rows: list[dict[str, Any]] = []
    for bucket in scripts:
        if bucket not in ("latin", "cyrillic"):
            continue
        for item in replacement_pairs.get(bucket, []) or []:
            left = _sanitize_term(str(item.get("from", "")))
            right = _sanitize_term(str(item.get("to", "")))
            if not left or not right:
                continue
            auto_rows.append(
                {
                    "source": "auto",
                    "from": left,
                    "to": right,
                    "count": int(item.get("count", 0) or 0),
                    "bucket": bucket,
                }
            )
    auto_rows.sort(key=lambda r: (-int(r.get("count") or 0), canonical_term_key(r["from"])))
    return rows + auto_rows


def _auto_pair_entries_for_scripts(replacement_pairs: dict, scripts: set[str]) -> list[dict]:
    pairs: list[dict] = []
    for script in scripts:
        if script not in ("latin", "cyrillic"):
            continue
        pairs.extend(replacement_pairs.get(script, []) or [])
    pairs.sort(key=lambda item: -int(item.get("count", 0) or 0))
    return pairs


def _merge_misrecognition_pairs(
    config: dict | None,
    languages: list[str] | None,
    cap: int,
    min_count: int,
) -> list[tuple[str, str]]:
    manual = manual_replacement_tuples(config)
    if len(manual) >= cap:
        return manual[:cap]

    index = _load_corrections_index()
    replacement_pairs = index.get("replacement_pairs") or {}
    scripts = {"latin", "cyrillic"}
    if languages:
        scripts = {get_language_script(lang) for lang in languages}

    seen: set[tuple[str, str]] = {
        (canonical_term_key(a), canonical_term_key(b)) for a, b in manual
    }
    result: list[tuple[str, str]] = list(manual)

    for item in _auto_pair_entries_for_scripts(replacement_pairs, scripts):
        count = int(item.get("count", 0) or 0)
        if count < min_count:
            continue
        left = _sanitize_term(str(item.get("from", "")))
        right = _sanitize_term(str(item.get("to", "")))
        if not left or not right:
            continue
        ck = (canonical_term_key(left), canonical_term_key(right))
        if ck in seen:
            continue
        seen.add(ck)
        result.append((left, right))
        if len(result) >= cap:
            break
    return result


def _compile_replacement_pattern(from_phrase: str) -> re.Pattern[str] | None:
    parts = from_phrase.split()
    if not parts:
        return None
    inner = r"\s+".join(re.escape(p) for p in parts)
    try:
        return re.compile(rf"(?<!\w)({inner})(?!\w)", re.IGNORECASE | re.UNICODE)
    except re.error:
        return None


def apply_replacements(text: str, pairs: list[tuple[str, str]]) -> str:
    """Whole-word / whole-phrase replace (case-insensitive on *from*).

    Pairs are matched against the original text and applied once, left-to-right,
    so replacement output is never rewritten by a later pair.
    """
    if not text or not pairs:
        return text
    matches: list[tuple[int, int, int, str]] = []
    for priority, (from_phrase, to_phrase) in enumerate(pairs):
        pattern = _compile_replacement_pattern(from_phrase)
        if pattern is None:
            continue
        for match in pattern.finditer(text):
            matches.append((match.start(), match.end(), priority, to_phrase))
    if not matches:
        return text

    matches.sort(key=lambda m: (m[0], -(m[1] - m[0]), m[2]))
    out: list[str] = []
    pos = 0
    for start, end, _priority, to_phrase in matches:
        if start < pos:
            continue
        out.append(text[pos:start])
        out.append(to_phrase)
        pos = end
    out.append(text[pos:])
    return "".join(out)


def apply_replacements_sequential(text: str, pairs: list[tuple[str, str]]) -> str:
    """Legacy sequential replacement helper, kept only for tests/debugging."""
    if not text or not pairs:
        return text
    result = text
    for from_phrase, to_phrase in pairs:
        pattern = _compile_replacement_pattern(from_phrase)
        if pattern is None:
            continue
        result = pattern.sub(to_phrase, result)
    return result


def collect_replacement_pairs_for_apply(
    config: dict,
    languages: list[str] | None = None,
    cap: int = _REPLACEMENT_APPLY_CAP,
    min_count: int = _MISRECOGNITIONS_MIN_COUNT,
) -> list[tuple[str, str]]:
    """Manual pairs plus frequent auto pairs, sorted so longer *from* wins first."""
    merged = _merge_misrecognition_pairs(config, languages, cap, min_count)
    merged.sort(key=lambda p: (-len(p[0]), -len(canonical_term_key(p[0]))))
    return merged


def _load_corrections_index() -> dict:
    path = get_corrections_file_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}

    # Backward compatibility for legacy v1 keys.
    replacement_pairs = data.get("replacement_pairs") or {}
    if "latin" not in replacement_pairs and "en" in replacement_pairs:
        replacement_pairs = {
            "latin": replacement_pairs.get("en", []),
            "cyrillic": replacement_pairs.get("ru", []),
        }
        data["replacement_pairs"] = replacement_pairs
    return data


def collect_misrecognitions(
    languages: list[str] | None = None,
    cap: int = _MISRECOGNITIONS_CAP,
    min_count: int = _MISRECOGNITIONS_MIN_COUNT,
    config: dict | None = None,
) -> list[tuple[str, str]]:
    """Collect manual + frequent auto replacement pairs for ExternalApiEditor hints."""
    return _merge_misrecognition_pairs(config, languages, cap, min_count)
