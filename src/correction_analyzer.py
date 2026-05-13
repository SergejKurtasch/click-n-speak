import json
import re
from datetime import UTC, datetime, timedelta
from difflib import SequenceMatcher
from pathlib import Path

from .dataset_logger import _DEFAULT_DATASET_PATH
from .log_analyzer import RUS_FUNCTION_WORDS, TERM_STOPLIST, _whisper_token_count
from .utils import (
    canonical_term_key,
    canonicalize_term,
    existing_terms_union_for_script,
    get_corrections_file_path,
    log_info,
    skipped_phrases_merge_for_script,
    write_json_atomic,
)

_TOKEN_RE = re.compile(r"[A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё0-9+#._-]*")
_CYRILLIC_RE = re.compile(r"[А-Яа-яЁё]")
_LATIN_RE = re.compile(r"[A-Za-z]")
_DIGITS_ONLY_RE = re.compile(r"^\d+$")
_PUNCT_STRIP_RE = re.compile(r"[^\w\s]", re.UNICODE)
_HALLUCINATION_REPEAT_RE = re.compile(r"(.{2,4})\1{7,}")
_MAX_PAIR_TOKEN_LEN = 30
_DEFAULT_INDEX_PATH = get_corrections_file_path()
_SCHEMA_VERSION = 3


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def _tokenize(text: str) -> list[str]:
    return _TOKEN_RE.findall(text or "")


def _norm_cmp(text: str) -> str:
    return " ".join(_PUNCT_STRIP_RE.sub("", (text or "").lower()).split())


def _lang_bucket(token: str) -> str | None:
    has_cyr = bool(_CYRILLIC_RE.search(token))
    has_lat = bool(_LATIN_RE.search(token))
    if has_cyr and not has_lat:
        return "cyrillic"
    if has_lat and not has_cyr:
        return "latin"
    return None


def _is_valid_term(token: str) -> bool:
    token = canonicalize_term(token)
    if len(token) < 2:
        return False
    lower = canonical_term_key(token)
    if lower in TERM_STOPLIST or lower in RUS_FUNCTION_WORDS:
        return False
    if _DIGITS_ONLY_RE.match(token):
        return False
    lang = _lang_bucket(token)
    if lang is None:
        return False
    # Cyrillic words Whisper already handles perfectly (1–2 BPE tokens) add no
    # value to the initial_prompt and mostly produce noise suggestions.
    if lang == "cyrillic" and _whisper_token_count(token) < 3:
        return False
    return True


def _default_index() -> dict:
    return {
        "schema_version": _SCHEMA_VERSION,
        "last_processed_ts": None,
        "processed_rows": 0,
        "inserted_terms": {"latin": {}, "cyrillic": {}},
        "replacement_pairs": {"latin": [], "cyrillic": []},
    }


def _is_hallucination_pair(from_str: str, to_str: str) -> bool:
    """True when either side is a repetitive-pattern hallucination or an overlong token."""
    for s in (from_str, to_str):
        for token in s.split():
            if len(token) > _MAX_PAIR_TOKEN_LEN:
                return True
            if _HALLUCINATION_REPEAT_RE.search(token):
                return True
    return False


def _migrate_corrections_index_to_v2(data: dict) -> dict:
    """Rename legacy script keys 'en'/'ru' → 'latin'/'cyrillic'. Idempotent for v2+."""
    ver = int(data.get("schema_version", 1))
    if ver >= 2:
        return data
    old_ins = data.get("inserted_terms") or {}
    old_pairs = data.get("replacement_pairs") or {}
    latin_terms = dict(old_ins.get("latin") or old_ins.get("en") or {})
    cyrillic_terms = dict(old_ins.get("cyrillic") or old_ins.get("ru") or {})
    latin_pairs = list(old_pairs.get("latin") or old_pairs.get("en") or [])
    cyrillic_pairs = list(old_pairs.get("cyrillic") or old_pairs.get("ru") or [])
    data["inserted_terms"] = {"latin": latin_terms, "cyrillic": cyrillic_terms}
    data["replacement_pairs"] = {"latin": latin_pairs, "cyrillic": cyrillic_pairs}
    data["schema_version"] = 2
    return data


def _migrate_corrections_index_to_v3(data: dict) -> dict:
    """Clean replacement_pairs: remove self-replace, hallucinations, merge duplicates."""
    ver = int(data.get("schema_version", 1))
    if ver >= 3:
        return data
    rp = data.get("replacement_pairs") or {}
    for bucket in ("latin", "cyrillic"):
        pairs = rp.get(bucket) or []
        merged: dict[tuple[str, str], dict] = {}
        for item in pairs:
            left = canonicalize_term(str(item.get("from", "")))
            right = canonicalize_term(str(item.get("to", "")))
            if not left or not right:
                continue
            if canonical_term_key(left) == canonical_term_key(right):
                continue
            if _is_hallucination_pair(left, right):
                continue
            key = (canonical_term_key(left), canonical_term_key(right))
            count = int(item.get("count", 1) or 1)
            last_seen = str(item.get("last_seen") or "")
            if key in merged:
                merged[key]["count"] += count
                if last_seen > merged[key].get("last_seen", ""):
                    merged[key]["last_seen"] = last_seen
            else:
                merged[key] = {"from": left, "to": right, "count": count, "last_seen": last_seen}
        cleaned = sorted(merged.values(), key=lambda x: -int(x.get("count", 0)))
        rp[bucket] = cleaned
    data["replacement_pairs"] = rp
    data["schema_version"] = 3
    log_info("correction_analyzer: migrated replacement_pairs to v3 (removed self-replace + hallucinations)")
    return data


def _read_index(path: Path) -> dict:
    if not path.exists():
        return _default_index()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return _default_index()
    data = _migrate_corrections_index_to_v2(data)
    data = _migrate_corrections_index_to_v3(data)
    if int(data.get("schema_version", 0)) != _SCHEMA_VERSION:
        return _default_index()
    data.setdefault("processed_rows", 0)
    ins = data.get("inserted_terms")
    if not isinstance(ins, dict):
        ins = {"latin": {}, "cyrillic": {}}
        data["inserted_terms"] = ins
    ins.setdefault("latin", {})
    ins.setdefault("cyrillic", {})
    rp = data.get("replacement_pairs")
    if not isinstance(rp, dict):
        rp = {"latin": [], "cyrillic": []}
        data["replacement_pairs"] = rp
    rp.setdefault("latin", [])
    rp.setdefault("cyrillic", [])
    return data


def _iter_new_records(dataset_path: Path, last_processed_ts: datetime | None) -> list[dict]:
    if not dataset_path.exists():
        return []
    out: list[dict] = []
    with dataset_path.open("r", encoding="utf-8") as f:
        for line_no, raw in enumerate(f, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw)
            except Exception:
                log_info(f"correction_analyzer: skipping malformed dataset line {line_no}")
                continue
            ts = _parse_iso(record.get("timestamp"))
            if ts is None:
                continue
            if last_processed_ts is not None and ts <= last_processed_ts:
                continue
            out.append(record)
    out.sort(key=lambda r: r.get("timestamp", ""))
    return out


def _upsert_inserted(index: dict, token: str, ts: str, *, weight: float) -> None:
    token = canonicalize_term(token)
    lang = _lang_bucket(token)
    if lang is None or not _is_valid_term(token):
        return
    bucket = index["inserted_terms"][lang]
    key = canonical_term_key(token)
    existing = bucket.get(key)
    if not existing:
        bucket[key] = {
            "term": token,
            "count": 1,
            "weighted_count": weight,
            "first_seen": ts,
            "last_seen": ts,
            "last_seen_row": index["processed_rows"],
        }
        return
    existing["count"] += 1
    existing["weighted_count"] = float(existing.get("weighted_count", existing["count"])) + weight
    existing["last_seen"] = ts
    existing["last_seen_row"] = index["processed_rows"]
    # Keep the first-seen casing unless a title-case variant appears.
    if existing.get("term", "").islower() and any(c.isupper() for c in token):
        existing["term"] = token


def _upsert_replacement_pair(index: dict, from_tokens: list[str], to_tokens: list[str], ts: str) -> None:
    from_tokens = [canonicalize_term(t) for t in from_tokens]
    to_tokens = [canonicalize_term(t) for t in to_tokens]
    from_tokens = [t for t in from_tokens if t]
    to_tokens = [t for t in to_tokens if t]
    if not from_tokens or not to_tokens:
        return
    if len(from_tokens) > 4 or len(to_tokens) > 4:
        return
    to_langs = {_lang_bucket(t) for t in to_tokens}
    to_langs.discard(None)
    if len(to_langs) != 1:
        return
    lang = next(iter(to_langs))
    if any(not _is_valid_term(t) for t in to_tokens):
        return
    to_str = " ".join(to_tokens)
    from_str = " ".join(from_tokens)
    # Drop self-replace (only punctuation/case changed — not a meaningful correction).
    if canonical_term_key(from_str) == canonical_term_key(to_str):
        return
    # Drop hallucination tokens.
    if _is_hallucination_pair(from_str, to_str):
        return
    pairs = index["replacement_pairs"][lang]
    for item in pairs:
        if canonical_term_key(item.get("from", "")) == canonical_term_key(from_str) and canonical_term_key(
            item.get("to", "")
        ) == canonical_term_key(to_str):
            item["count"] = int(item.get("count", 0)) + 1
            item["last_seen"] = ts
            return
    pairs.append({"from": from_str, "to": to_str, "count": 1, "last_seen": ts})


def _process_diff(index: dict, source_text: str, user_text: str, ts: str) -> None:
    src_tokens = _tokenize(source_text)
    usr_tokens = _tokenize(user_text)
    src_lower = {_norm_cmp(t) for t in src_tokens}
    matcher = SequenceMatcher(a=[_norm_cmp(t) for t in src_tokens], b=[_norm_cmp(t) for t in usr_tokens])
    for op, i1, i2, j1, j2 in matcher.get_opcodes():
        if op == "equal" or op == "delete":
            continue
        to_tokens = usr_tokens[j1:j2]
        if op in {"insert", "replace"}:
            for token in to_tokens:
                lowered = _norm_cmp(token)
                weight = 0.5 if lowered in src_lower else 1.0
                _upsert_inserted(index, token, ts, weight=weight)
        if op == "replace":
            _upsert_replacement_pair(index, src_tokens[i1:i2], to_tokens, ts)


def update_corrections_index(
    dataset_path: Path = Path(_DEFAULT_DATASET_PATH),
    index_path: Path = _DEFAULT_INDEX_PATH,
) -> dict:
    """Read new dataset records and update corrections index incrementally."""
    index = _read_index(index_path)
    last_ts = _parse_iso(index.get("last_processed_ts"))
    new_records = _iter_new_records(dataset_path, last_ts)
    if not new_records:
        return index

    for record in new_records:
        ts = record.get("timestamp")
        if not isinstance(ts, str):
            continue
        base = record.get("ai_edited") or record.get("raw_whisper") or ""
        raw = record.get("raw_whisper") or ""
        user_final = record.get("user_final") or ""
        if not user_final:
            continue
        index["processed_rows"] = int(index.get("processed_rows", 0)) + 1
        _process_diff(index, base, user_final, ts)
        if _norm_cmp(raw) != _norm_cmp(base):
            _process_diff(index, raw, user_final, ts)
        index["last_processed_ts"] = ts

    write_json_atomic(index_path, index, indent=2)
    return index


def remove_replacement_pair_from_index(
    bucket: str,
    from_text: str,
    to_text: str,
    index_path: Path | None = None,
) -> bool:
    """Remove one replacement pair from *replacement_pairs* (by canonical keys).

    Returns True if the index file was updated.
    """
    if bucket not in ("latin", "cyrillic"):
        return False
    path = index_path or _DEFAULT_INDEX_PATH
    index = _read_index(path)
    fk = canonical_term_key(canonicalize_term(from_text))
    tk = canonical_term_key(canonicalize_term(to_text))
    rp = index["replacement_pairs"]
    pairs = list(rp.get(bucket, []) or [])
    new_pairs: list[dict] = []
    removed = False
    for item in pairs:
        if canonical_term_key(canonicalize_term(str(item.get("from", "")))) == fk and canonical_term_key(
            canonicalize_term(str(item.get("to", "")))
        ) == tk:
            removed = True
            continue
        new_pairs.append(item)
    if not removed:
        log_info(
            "correction_analyzer: remove_replacement_pair_from_index — no matching pair "
            f"in bucket={bucket!r} for {from_text!r} -> {to_text!r}"
        )
        return False
    rp[bucket] = new_pairs
    index["replacement_pairs"] = rp
    write_json_atomic(path, index, indent=2)
    return True


def get_correction_candidates(
    index: dict,
    existing_lower_by_lang: dict[str, set[str]],
    skipped_lower_by_lang: dict[str, dict[str, int]],
    current_phrase_count: int,
    min_correction_count: dict[str, int] | int = 2,
    cooldown_phrases: int = 100,
    max_per_lang: int = 20,
    max_age_days: int = 60,
) -> dict[str, list[dict]]:
    """Build prompt candidates from the corrections index.

    min_correction_count may be a dict {"latin": N, "cyrillic": M} for per-script
    thresholds, or a single int applied to both scripts.
    """
    if isinstance(min_correction_count, dict):
        min_by_script: dict[str, int] = min_correction_count
    else:
        min_by_script = {"latin": min_correction_count, "cyrillic": min_correction_count}

    result: dict[str, list[dict]] = {}
    now = datetime.now(UTC)
    age_limit = now - timedelta(days=max_age_days)
    for lang in ("latin", "cyrillic"):
        min_count = int(min_by_script.get(lang, 2))
        existing = existing_terms_union_for_script(existing_lower_by_lang, lang)
        skipped = skipped_phrases_merge_for_script(skipped_lower_by_lang, lang)
        terms = index.get("inserted_terms", {}).get(lang, {})
        items: list[dict] = []
        for lower, payload in terms.items():
            count = int(payload.get("count", 0))
            if count < min_count:
                continue
            if canonical_term_key(lower) in existing:
                continue
            skipped_at = int(skipped.get(canonical_term_key(lower), -1))
            if skipped_at >= 0 and current_phrase_count - skipped_at < cooldown_phrases:
                continue
            seen_dt = _parse_iso(payload.get("last_seen"))
            if seen_dt is not None and seen_dt < age_limit:
                continue
            items.append(
                {
                    "term": canonicalize_term(payload.get("term", lower)),
                    "count": count,
                    "correction_count": count,
                    "frequency_count": 0,
                    "source": "correction",
                }
            )
        items.sort(key=lambda x: (-int(x.get("correction_count", 0)), canonical_term_key(x["term"])))
        if items:
            result[lang] = items[:max_per_lang]
    return result


def has_fresh_strong_correction_signal(
    index: dict,
    current_phrase_count: int,
    recent_phrase_window: int = 10,
    min_count: int = 2,
    already_processed_rows: int = 0,
) -> bool:
    """Check if any repeated inserted term was seen in the recent window.

    already_processed_rows: processed_rows value from the last fast-path trigger.
    If the index has not grown since then, returns False (prevents re-triggering
    on the same data).
    """
    _ = current_phrase_count  # Reserved for future exact phrase-number tracking.
    latest_row = int(index.get("processed_rows", 0))
    if latest_row <= 0 or latest_row <= already_processed_rows:
        return False
    for lang in ("latin", "cyrillic"):
        for payload in index.get("inserted_terms", {}).get(lang, {}).values():
            count = int(payload.get("count", 0))
            if count < min_count:
                continue
            last_seen_row = int(payload.get("last_seen_row", 0))
            if latest_row - last_seen_row <= recent_phrase_window:
                return True
    return False
