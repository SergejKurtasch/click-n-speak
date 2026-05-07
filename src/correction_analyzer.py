import json
import re
from datetime import UTC, datetime, timedelta
from difflib import SequenceMatcher
from pathlib import Path

from .dataset_logger import _DEFAULT_DATASET_PATH
from .log_analyzer import RUS_FUNCTION_WORDS, TERM_STOPLIST
from .utils import (
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
_DEFAULT_INDEX_PATH = get_corrections_file_path()
_SCHEMA_VERSION = 2


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
    return (text or "").strip().lower()


def _lang_bucket(token: str) -> str | None:
    has_cyr = bool(_CYRILLIC_RE.search(token))
    has_lat = bool(_LATIN_RE.search(token))
    if has_cyr and not has_lat:
        return "cyrillic"
    if has_lat and not has_cyr:
        return "latin"
    return None


def _is_valid_term(token: str) -> bool:
    if len(token) < 2:
        return False
    lower = token.lower()
    if lower in TERM_STOPLIST or lower in RUS_FUNCTION_WORDS:
        return False
    if _DIGITS_ONLY_RE.match(token):
        return False
    return _lang_bucket(token) is not None


def _default_index() -> dict:
    return {
        "schema_version": _SCHEMA_VERSION,
        "last_processed_ts": None,
        "processed_rows": 0,
        "inserted_terms": {"latin": {}, "cyrillic": {}},
        "replacement_pairs": {"latin": [], "cyrillic": []},
    }


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


def _read_index(path: Path) -> dict:
    if not path.exists():
        return _default_index()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return _default_index()
    data = _migrate_corrections_index_to_v2(data)
    if int(data.get("schema_version", 0)) != _SCHEMA_VERSION:
        return _default_index()
    data.setdefault("processed_rows", 0)
    data.setdefault("inserted_terms", {"latin": {}, "cyrillic": {}})
    data.setdefault("replacement_pairs", {"latin": [], "cyrillic": []})
    data["inserted_terms"].setdefault("latin", {})
    data["inserted_terms"].setdefault("cyrillic", {})
    data["replacement_pairs"].setdefault("latin", [])
    data["replacement_pairs"].setdefault("cyrillic", [])
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
    lang = _lang_bucket(token)
    if lang is None or not _is_valid_term(token):
        return
    bucket = index["inserted_terms"][lang]
    key = token.lower()
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
    pairs = index["replacement_pairs"][lang]
    for item in pairs:
        if item.get("from", "").lower() == from_str.lower() and item.get("to", "").lower() == to_str.lower():
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


def get_correction_candidates(
    index: dict,
    existing_lower_by_lang: dict[str, set[str]],
    skipped_lower_by_lang: dict[str, dict[str, int]],
    current_phrase_count: int,
    min_correction_count: int = 2,
    cooldown_phrases: int = 100,
    max_per_lang: int = 20,
    max_age_days: int = 60,
) -> dict[str, list[dict]]:
    """Build prompt candidates from the corrections index."""
    result: dict[str, list[dict]] = {}
    now = datetime.now(UTC)
    age_limit = now - timedelta(days=max_age_days)
    for lang in ("latin", "cyrillic"):
        existing = existing_terms_union_for_script(existing_lower_by_lang, lang)
        skipped = skipped_phrases_merge_for_script(skipped_lower_by_lang, lang)
        terms = index.get("inserted_terms", {}).get(lang, {})
        items: list[dict] = []
        for lower, payload in terms.items():
            count = int(payload.get("count", 0))
            if count < min_correction_count:
                continue
            if lower in existing:
                continue
            skipped_at = int(skipped.get(lower, -1))
            if skipped_at >= 0 and current_phrase_count - skipped_at < cooldown_phrases:
                continue
            seen_dt = _parse_iso(payload.get("last_seen"))
            if seen_dt is not None and seen_dt < age_limit:
                continue
            items.append(
                {
                    "term": payload.get("term", lower),
                    "count": count,
                    "correction_count": count,
                    "frequency_count": 0,
                    "source": "correction",
                }
            )
        items.sort(key=lambda x: (-int(x.get("correction_count", 0)), x["term"].lower()))
        if items:
            result[lang] = items[:max_per_lang]
    return result


def has_fresh_strong_correction_signal(
    index: dict,
    current_phrase_count: int,
    recent_phrase_window: int = 10,
    min_count: int = 2,
) -> bool:
    """Check if any repeated inserted term was seen in the recent window."""
    _ = current_phrase_count  # Reserved for future exact phrase-number tracking.
    latest_row = int(index.get("processed_rows", 0))
    if latest_row <= 0:
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
