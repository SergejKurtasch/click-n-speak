from __future__ import annotations

import json
import os
import tempfile
from collections import deque
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from .log_analyzer import _levenshtein
from .utils import (
    _MAX_PROMPT_TOKENS,
    _count_prompt_tokens,
    _term_is_active,
    _term_str,
    build_initial_prompt,
    canonical_term_key,
)

_TOKEN_RE = __import__("re").compile(r"[A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё0-9+#._-]*")
_HISTORY_ROTATE_BYTES = 1_000_000
_HISTORY_KEEP_DAYS = 365


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def _tokenize(text: str) -> set[str]:
    return {t.lower() for t in _TOKEN_RE.findall(text or "")}


def _safe_ratio(numerator: float, denominator: float) -> float | None:
    if denominator <= 0:
        return None
    return numerator / denominator


def _edit_score_char(base: str, final: str) -> float:
    max_len = max(len(base), len(final), 1)
    return _levenshtein(base, final) / max_len


def _read_dataset_tail(path: Path, limit: int) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: deque[dict[str, Any]] = deque(maxlen=limit)
    try:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                raw = line.strip()
                if not raw:
                    continue
                try:
                    rows.append(json.loads(raw))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return list(rows)


def _read_corrections(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    pairs = data.get("replacement_pairs") or {}
    if "latin" not in pairs and "en" in pairs:
        data["replacement_pairs"] = {
            "latin": pairs.get("en", []),
            "cyrillic": pairs.get("ru", []),
        }
    return data


def _split_windows(records: list[dict[str, Any]], window_size: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if window_size <= 0:
        return records, []
    current = records[-window_size:]
    previous = records[-2 * window_size:-window_size]
    return current, previous


def _window_edit_score(records: list[dict[str, Any]]) -> float | None:
    values: list[float] = []
    for row in records:
        user_final = str(row.get("user_final") or "").strip()
        if not user_final:
            continue
        base = str(row.get("ai_edited") or row.get("raw_whisper") or "").strip()
        values.append(_edit_score_char(base, user_final))
    if not values:
        return None
    return sum(values) / len(values)


def _active_terms_by_lang(config: dict) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for lang, items in (config.get("user_terms") or {}).items():
        terms = [_term_str(item) for item in items if _term_is_active(item)]
        if terms:
            out[lang] = terms
    return out


def _dictionary_hit_rate(records: list[dict[str, Any]], config: dict) -> float | None:
    if not records:
        return None
    active_terms: list[str] = []
    for terms in _active_terms_by_lang(config).values():
        active_terms.extend(terms)
    if not active_terms:
        return 0.0
    active_lowers = {canonical_term_key(t) for t in active_terms}
    hits = 0
    valid = 0
    for row in records:
        final = str(row.get("user_final") or "").strip()
        if not final:
            continue
        valid += 1
        tokens = _tokenize(final)
        if active_lowers.intersection(tokens):
            hits += 1
    if valid == 0:
        return None
    return hits / valid


def _terms_catalogue_health(config: dict) -> dict[str, Any]:
    now = datetime.now(UTC)
    active = 0
    inactive = 0
    by_source = {"manual": 0, "auto": 0, "correction": 0}
    oldest_age_days = 0

    for items in (config.get("user_terms") or {}).values():
        for item in items:
            if isinstance(item, dict):
                if item.get("inactive"):
                    inactive += 1
                else:
                    active += 1
                    src = item.get("source", "manual")
                    by_source[src] = by_source.get(src, 0) + 1
                    seen = _parse_iso(item.get("last_seen") or item.get("added_at"))
                    if seen is not None:
                        age = max(0, (now - seen).days)
                        oldest_age_days = max(oldest_age_days, age)
            else:
                active += 1
                by_source["manual"] = by_source.get("manual", 0) + 1

    return {
        "active_terms_count": active,
        "inactive_terms_count": inactive,
        "manual_terms_count": by_source.get("manual", 0),
        "auto_terms_count": by_source.get("auto", 0),
        "correction_terms_count": by_source.get("correction", 0),
        "oldest_active_age_days": oldest_age_days,
    }


def _candidate_funnel(config: dict) -> dict[str, Any]:
    pending = config.get("pending_suggestions") or {}
    skipped = config.get("skipped_terms") or {}
    user_terms = config.get("user_terms") or {}

    pending_now = sum(len(items or []) for items in pending.values())
    rejected_total = sum(len(items or {}) for items in skipped.values())
    accepted_total = 0
    for items in user_terms.values():
        for item in items:
            if isinstance(item, dict) and item.get("source") in {"auto", "correction"}:
                accepted_total += 1
    proposed_total = accepted_total + rejected_total + pending_now
    denominator = accepted_total + rejected_total
    acceptance_rate = _safe_ratio(accepted_total, denominator) if denominator else None

    return {
        "proposed_total": proposed_total,
        "accepted_total": accepted_total,
        "rejected_total": rejected_total,
        "pending_now": pending_now,
        "acceptance_rate": acceptance_rate,
        "acceptance_rate_scope": "lifetime",
    }


def _prompt_utilisation(config: dict) -> dict[str, Any]:
    prompt = build_initial_prompt(config)
    used = _count_prompt_tokens(prompt)
    max_tokens = _MAX_PROMPT_TOKENS
    return {
        "prompt_tokens_used": used,
        "prompt_tokens_max": max_tokens,
        "prompt_utilisation": min(1.0, used / max_tokens) if max_tokens else None,
    }


def _correction_recurrence(corrections: dict[str, Any], lookback_days: int = 30, min_recent_count: int = 3) -> dict[str, Any]:
    pairs = corrections.get("replacement_pairs") or {}
    now = datetime.now(UTC)
    cutoff = now - timedelta(days=lookback_days)
    failing: list[dict[str, Any]] = []
    for bucket in ("latin", "cyrillic"):
        for item in pairs.get(bucket, []) or []:
            count = int(item.get("count", 0) or 0)
            if count < min_recent_count:
                continue
            seen = _parse_iso(item.get("last_seen"))
            if seen is None or seen < cutoff:
                continue
            failing.append(
                {
                    "bucket": bucket,
                    "from": str(item.get("from", "")),
                    "to": str(item.get("to", "")),
                    "count": count,
                    "last_seen": item.get("last_seen"),
                }
            )
    failing.sort(key=lambda x: -int(x.get("count", 0)))
    return {
        "failed_pairs": failing,
        "failed_pairs_count": len(failing),
        "lookback_days": lookback_days,
    }


def _trend(current: float | None, previous: float | None) -> dict[str, Any]:
    if current is None or previous is None:
        return {"delta": None, "direction": "none"}
    delta = current - previous
    if abs(delta) < 1e-9:
        direction = "flat"
    elif delta > 0:
        direction = "up"
    else:
        direction = "down"
    return {"delta": delta, "direction": direction}


def compute_metrics(
    dataset_path: Path,
    corrections_path: Path,
    config: dict,
    window_size: int = 100,
) -> dict[str, Any]:
    records = _read_dataset_tail(dataset_path, max(window_size * 2, 200))
    current, previous = _split_windows(records, window_size)
    corrections = _read_corrections(corrections_path)

    current_edit = _window_edit_score(current)
    previous_edit = _window_edit_score(previous)
    current_hit = _dictionary_hit_rate(current, config)
    previous_hit = _dictionary_hit_rate(previous, config)

    terms_health = _terms_catalogue_health(config)
    funnel = _candidate_funnel(config)
    prompt = _prompt_utilisation(config)
    recurrence = _correction_recurrence(corrections)

    return {
        "ts": datetime.now(UTC).isoformat(),
        "window_size": window_size,
        "dataset_records_total": len(records),
        "current_window_count": len(current),
        "previous_window_count": len(previous),
        "edit_score_avg": current_edit,
        "edit_score_prev_avg": previous_edit,
        "edit_score_trend": _trend(current_edit, previous_edit),
        "hit_rate": current_hit,
        "hit_rate_prev": previous_hit,
        "hit_rate_trend": _trend(current_hit, previous_hit),
        **terms_health,
        **funnel,
        **prompt,
        **recurrence,
    }


def _filter_history_window(entries: list[dict[str, Any]], max_days: int) -> list[dict[str, Any]]:
    if max_days <= 0:
        return entries
    cutoff = datetime.now(UTC) - timedelta(days=max_days)
    out: list[dict[str, Any]] = []
    for item in entries:
        ts = _parse_iso(item.get("ts"))
        if ts is None or ts >= cutoff:
            out.append(item)
    return out


def load_metrics_history(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return rows


def rotate_metrics_history_if_needed(path: Path, max_bytes: int = _HISTORY_ROTATE_BYTES) -> None:
    if not path.exists():
        return
    try:
        if path.stat().st_size <= max_bytes:
            return
    except OSError:
        return
    backup = path.with_suffix(path.suffix + ".1")
    try:
        if backup.exists():
            backup.unlink()
        path.rename(backup)
    except OSError:
        return


def append_metrics_history(
    path: Path,
    snapshot: dict[str, Any],
    keep_days: int = _HISTORY_KEEP_DAYS,
) -> None:
    entries = load_metrics_history(path)
    entries.append(snapshot)
    entries = _filter_history_window(entries, keep_days)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_payload = "\n".join(json.dumps(item, ensure_ascii=False) for item in entries)
    _write_text_atomic(path, tmp_payload + ("\n" if tmp_payload else ""))
    rotate_metrics_history_if_needed(path)


def _write_text_atomic(path: Path, text: str) -> None:
    tmp_path: Path | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        tmp_path = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
                f.flush()
                os.fsync(f.fileno())
        except Exception:
            os.close(fd)
            raise
        os.replace(tmp_path, path)
    except OSError:
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass
        raise

