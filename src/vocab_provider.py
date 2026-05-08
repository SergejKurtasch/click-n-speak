import json
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


def _sanitize_term(text: str) -> str:
    """Keep prompt payload single-line and quote-safe."""
    cleaned = (text or "").replace("\n", " ").replace("\r", " ").replace('"', "'").strip()
    return canonicalize_term(" ".join(cleaned.split()))


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
) -> list[tuple[str, str]]:
    """Collect frequent replacement pairs from corrections index for active scripts."""
    index = _load_corrections_index()
    replacement_pairs = index.get("replacement_pairs") or {}
    if not replacement_pairs:
        return []

    scripts = {"latin", "cyrillic"}
    if languages:
        scripts = {get_language_script(lang) for lang in languages}

    pairs: list[dict] = []
    for script in scripts:
        pairs.extend(replacement_pairs.get(script, []) or [])

    pairs.sort(key=lambda item: -int(item.get("count", 0) or 0))

    result: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for item in pairs:
        count = int(item.get("count", 0) or 0)
        if count < min_count:
            continue
        left = _sanitize_term(str(item.get("from", "")))
        right = _sanitize_term(str(item.get("to", "")))
        if not left or not right:
            continue
        key = (canonical_term_key(left), canonical_term_key(right))
        if key in seen:
            continue
        seen.add(key)
        result.append((left, right))
        if len(result) >= cap:
            break
    return result
