"""Tests for v5 schema migration, apply_decay, update_term_usage, and build_initial_prompt priority."""

from datetime import datetime, timedelta, timezone

import pytest

from src.utils import (
    apply_decay,
    build_initial_prompt,
    migrate_config_to_v5,
    update_term_usage,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _iso_days_ago(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()


def _make_v4_config(terms_by_lang: dict[str, list[str]]) -> dict:
    return {
        "schema_version": 4,
        "primary_language": "ru",
        "additional_languages": [],
        "user_terms": terms_by_lang,
        "initial_prompt": "",
    }


def _make_v5_config(terms_by_lang: dict[str, list[dict]]) -> dict:
    return {
        "schema_version": 5,
        "primary_language": "ru",
        "additional_languages": [],
        "user_terms": terms_by_lang,
        "initial_prompt": "",
        "last_decay_run_ts": None,
        "max_dictionary_age_days": 60,
    }


# ---------------------------------------------------------------------------
# 1. Migration v4 → v5
# ---------------------------------------------------------------------------

def test_v4_to_v5_migration_converts_strings():
    cfg = _make_v4_config({"ru": ["термин1", "MLX"], "en": ["GitHub"]})
    result = migrate_config_to_v5(cfg)

    assert result["schema_version"] == 5
    ru_terms = result["user_terms"]["ru"]
    assert len(ru_terms) == 2
    for item in ru_terms:
        assert isinstance(item, dict)
        assert item["source"] == "manual"
        assert item["use_count"] == 0
        assert "added_at" in item
        assert "last_seen" in item

    en_terms = result["user_terms"]["en"]
    assert en_terms[0]["term"] == "GitHub"
    assert en_terms[0]["source"] == "manual"


def test_v4_to_v5_migration_preserves_term_values():
    cfg = _make_v4_config({"ru": ["нейросеть", "PCA"]})
    result = migrate_config_to_v5(cfg)
    terms = [t["term"] for t in result["user_terms"]["ru"]]
    assert terms == ["нейросеть", "PCA"]


# ---------------------------------------------------------------------------
# 2. Migration idempotency
# ---------------------------------------------------------------------------

def test_v5_migration_is_idempotent():
    cfg = _make_v5_config({"ru": [
        {"term": "MLX", "source": "auto", "added_at": _now_iso(),
         "last_seen": _now_iso(), "use_count": 5}
    ]})
    original_item = cfg["user_terms"]["ru"][0].copy()
    result = migrate_config_to_v5(cfg)
    assert result["schema_version"] == 5
    assert result["user_terms"]["ru"][0] == original_item


# ---------------------------------------------------------------------------
# 3. apply_decay — marks old auto terms inactive
# ---------------------------------------------------------------------------

def test_apply_decay_marks_old_auto_inactive():
    cfg = _make_v5_config({"ru": [
        {"term": "старый", "source": "auto",
         "added_at": _iso_days_ago(90), "last_seen": _iso_days_ago(90),
         "use_count": 0}
    ]})
    n = apply_decay(cfg, max_age_days=60)
    assert n == 1
    assert cfg["user_terms"]["ru"][0]["inactive"] is True


# ---------------------------------------------------------------------------
# 4. apply_decay — never touches manual terms
# ---------------------------------------------------------------------------

def test_apply_decay_keeps_manual_terms():
    cfg = _make_v5_config({"ru": [
        {"term": "ручной", "source": "manual",
         "added_at": _iso_days_ago(90), "last_seen": _iso_days_ago(90),
         "use_count": 0}
    ]})
    n = apply_decay(cfg, max_age_days=60)
    assert n == 0
    assert not cfg["user_terms"]["ru"][0].get("inactive")


# ---------------------------------------------------------------------------
# 5. apply_decay — keeps recently-used auto terms
# ---------------------------------------------------------------------------

def test_apply_decay_keeps_recently_used():
    cfg = _make_v5_config({"ru": [
        {"term": "свежий", "source": "auto",
         "added_at": _iso_days_ago(10), "last_seen": _iso_days_ago(10),
         "use_count": 1}
    ]})
    n = apply_decay(cfg, max_age_days=60)
    assert n == 0
    assert not cfg["user_terms"]["ru"][0].get("inactive")


# ---------------------------------------------------------------------------
# 6. apply_decay — keeps high-use-count terms even if old
# ---------------------------------------------------------------------------

def test_apply_decay_keeps_high_use_count():
    cfg = _make_v5_config({"ru": [
        {"term": "популярный", "source": "auto",
         "added_at": _iso_days_ago(90), "last_seen": _iso_days_ago(90),
         "use_count": 10}
    ]})
    n = apply_decay(cfg, max_age_days=60)
    assert n == 0
    assert not cfg["user_terms"]["ru"][0].get("inactive")


# ---------------------------------------------------------------------------
# 7. update_term_usage — bumps counter when term appears in phrase
# ---------------------------------------------------------------------------

def test_update_term_usage_bumps_counter():
    old_ts = _iso_days_ago(30)
    cfg = _make_v5_config({"en": [
        {"term": "MLX", "source": "auto",
         "added_at": old_ts, "last_seen": old_ts, "use_count": 3}
    ]})
    dirty = update_term_usage(cfg, "I use MLX for inference")
    assert dirty is True
    item = cfg["user_terms"]["en"][0]
    assert item["use_count"] == 4
    assert item["last_seen"] > old_ts


def test_update_term_usage_no_match_returns_false():
    cfg = _make_v5_config({"en": [
        {"term": "MLX", "source": "auto",
         "added_at": _now_iso(), "last_seen": _now_iso(), "use_count": 0}
    ]})
    dirty = update_term_usage(cfg, "totally unrelated sentence")
    assert dirty is False
    assert cfg["user_terms"]["en"][0]["use_count"] == 0


# ---------------------------------------------------------------------------
# 8. update_term_usage — reactivates inactive term on match
# ---------------------------------------------------------------------------

def test_update_term_usage_reactivates_inactive():
    cfg = _make_v5_config({"en": [
        {"term": "MLX", "source": "auto",
         "added_at": _iso_days_ago(90), "last_seen": _iso_days_ago(90),
         "use_count": 0, "inactive": True}
    ]})
    update_term_usage(cfg, "MLX is back")
    item = cfg["user_terms"]["en"][0]
    assert not item.get("inactive")
    assert item["use_count"] == 1


# ---------------------------------------------------------------------------
# 9. build_initial_prompt — excludes inactive terms
# ---------------------------------------------------------------------------

def test_inactive_terms_excluded_from_prompt():
    cfg = _make_v5_config({"ru": [
        {"term": "активный", "source": "auto",
         "added_at": _now_iso(), "last_seen": _now_iso(), "use_count": 5},
        {"term": "неактивный", "source": "auto",
         "added_at": _iso_days_ago(90), "last_seen": _iso_days_ago(90),
         "use_count": 0, "inactive": True},
    ]})
    prompt = build_initial_prompt(cfg)
    assert "активный" in prompt
    assert "неактивный" not in prompt


# ---------------------------------------------------------------------------
# 10. build_initial_prompt — priority: manual > correction > auto (use_count desc)
# ---------------------------------------------------------------------------

def test_term_priority_in_prompt():
    """Manual terms come before correction, correction before auto; auto sorted by use_count desc."""
    cfg = _make_v5_config({"ru": [
        {"term": "авто_мало", "source": "auto",
         "added_at": _now_iso(), "last_seen": _now_iso(), "use_count": 1},
        {"term": "авто_много", "source": "auto",
         "added_at": _now_iso(), "last_seen": _now_iso(), "use_count": 20},
        {"term": "коррекция", "source": "correction",
         "added_at": _now_iso(), "last_seen": _now_iso(), "use_count": 5},
        {"term": "ручной", "source": "manual",
         "added_at": _now_iso(), "last_seen": _now_iso(), "use_count": 0},
    ]})
    prompt = build_initial_prompt(cfg)
    idx_manual = prompt.index("ручной")
    idx_correction = prompt.index("коррекция")
    idx_auto_high = prompt.index("авто_много")
    idx_auto_low = prompt.index("авто_мало")

    assert idx_manual < idx_correction, "manual should appear before correction"
    assert idx_correction < idx_auto_high, "correction should appear before auto"
    assert idx_auto_high < idx_auto_low, "higher use_count auto should appear first"
