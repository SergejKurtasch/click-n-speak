import json
from pathlib import Path

from src.metrics import (
    _edit_score_char,
    append_metrics_history,
    compute_metrics,
    dead_weight_terms,
    load_metrics_history,
    top_helping_terms,
)


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def _base_config() -> dict:
    return {
        "schema_version": 5,
        "primary_language": "ru",
        "additional_languages": ["en"],
        "user_terms": {
            "ru": [
                {
                    "term": "нейросеть",
                    "source": "manual",
                    "added_at": "2026-05-01T00:00:00+00:00",
                    "last_seen": "2026-05-07T00:00:00+00:00",
                    "use_count": 3,
                },
                {
                    "term": "устаревший",
                    "source": "auto",
                    "added_at": "2025-01-01T00:00:00+00:00",
                    "last_seen": "2025-01-05T00:00:00+00:00",
                    "use_count": 1,
                    "inactive": True,
                },
            ],
            "en": [
                {
                    "term": "GitHub",
                    "source": "correction",
                    "added_at": "2026-05-01T00:00:00+00:00",
                    "last_seen": "2026-05-07T00:00:00+00:00",
                    "use_count": 5,
                }
            ],
        },
        "pending_suggestions": {"en": [{"term": "MLX", "count": 3}]},
        "skipped_terms": {"en": {"cuda": 10}},
    }


def test_edit_score_zero_if_identical():
    assert _edit_score_char("same", "same") == 0.0


def test_edit_score_one_if_completely_different():
    assert _edit_score_char("aaaa", "bbbb") == 1.0


def test_hit_rate_and_active_terms_health(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    corrections = tmp_path / "corrections.json"
    rows = []
    for idx in range(100):
        text = "нейросеть и github" if idx < 30 else "обычная фраза"
        rows.append(
            {
                "timestamp": f"2026-05-07T12:{idx:02d}:00+00:00",
                "raw_whisper": text,
                "ai_edited": text,
                "user_final": text,
            }
        )
    _write_jsonl(dataset, rows)
    corrections.write_text(json.dumps({"replacement_pairs": {"latin": [], "cyrillic": []}}), encoding="utf-8")

    out = compute_metrics(dataset, corrections, _base_config(), window_size=100)
    assert out["hit_rate"] == 0.3
    assert out["active_terms_count"] == 2
    assert out["inactive_terms_count"] == 1


def test_hit_rate_matches_term_with_trailing_punctuation_in_dictionary(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    corrections = tmp_path / "corrections.json"
    rows = [
        {
            "timestamp": "2026-05-07T12:00:00+00:00",
            "raw_whisper": "github workflow",
            "ai_edited": "github workflow",
            "user_final": "github workflow",
        }
    ]
    _write_jsonl(dataset, rows)
    corrections.write_text(json.dumps({"replacement_pairs": {"latin": [], "cyrillic": []}}), encoding="utf-8")
    cfg = _base_config()
    cfg["user_terms"]["en"][0]["term"] = "GitHub."

    out = compute_metrics(dataset, corrections, cfg, window_size=10)
    assert out["hit_rate"] == 1.0


def test_acceptance_rate_from_config():
    cfg = _base_config()
    dataset = Path("/tmp/does-not-exist.jsonl")
    corrections = Path("/tmp/does-not-exist-corrections.json")
    out = compute_metrics(dataset, corrections, cfg, window_size=50)
    assert out["accepted_total"] == 2
    assert out["rejected_total"] == 1
    assert out["pending_now"] == 1
    assert out["acceptance_rate"] == 2 / 3


def test_correction_recurrence_flags_failed_pair(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    _write_jsonl(dataset, [])
    corrections = tmp_path / "corrections.json"
    corrections.write_text(
        json.dumps(
            {
                "replacement_pairs": {
                    "latin": [
                        {
                            "from": "piton",
                            "to": "Python",
                            "count": 10,
                            "last_seen": "2099-01-01T00:00:00+00:00",
                        }
                    ],
                    "cyrillic": [],
                }
            }
        ),
        encoding="utf-8",
    )
    out = compute_metrics(dataset, corrections, _base_config(), window_size=10)
    assert out["failed_pairs_count"] == 1
    assert out["failed_pairs"][0]["to"] == "Python"


def test_metrics_window_respects_size(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    corrections = tmp_path / "corrections.json"
    rows = []
    for idx in range(120):
        rows.append(
            {
                "timestamp": f"2026-05-07T12:{idx % 60:02d}:00+00:00",
                "raw_whisper": "raw",
                "ai_edited": "raw",
                "user_final": "final",
            }
        )
    _write_jsonl(dataset, rows)
    corrections.write_text(json.dumps({"replacement_pairs": {"latin": [], "cyrillic": []}}), encoding="utf-8")
    out = compute_metrics(dataset, corrections, _base_config(), window_size=50)
    assert out["current_window_count"] == 50
    assert out["previous_window_count"] == 50


def test_metrics_history_append_and_rotation(tmp_path):
    history = tmp_path / "metrics_history.jsonl"
    for i in range(20):
        append_metrics_history(
            history,
            {
                "ts": f"2026-05-{(i % 28) + 1:02d}T00:00:00+00:00",
                "edit_score_avg": 0.1 + i / 1000,
                "hit_rate": 0.2,
            },
            keep_days=1000,
        )
    rows = load_metrics_history(history)
    assert len(rows) == 20
    for row in rows:
        assert isinstance(row, dict)


# ---------------------------------------------------------------------------
# top_helping_terms
# ---------------------------------------------------------------------------

def _write_dataset(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def test_top_helping_empty_dataset(tmp_path):
    p = tmp_path / "ds.jsonl"
    assert top_helping_terms(p) == []


def test_top_helping_no_tracking_fields(tmp_path):
    p = tmp_path / "ds.jsonl"
    _write_dataset(p, [{"raw_whisper": "text", "user_final": "text"}])
    assert top_helping_terms(p) == []


def test_top_helping_perfect_recognition(tmp_path):
    p = tmp_path / "ds.jsonl"
    records = [
        {
            "vocab_terms_in_raw": ["MLX", "Whisper"],
            "vocab_terms_in_final": ["MLX", "Whisper"],
        }
        for _ in range(5)
    ]
    results = top_helping_terms(p, limit=5)
    assert len(results) == 0  # dataset not written yet
    _write_dataset(p, records)
    results = top_helping_terms(p, limit=5)
    assert len(results) == 2
    for r in results:
        assert r["recognition_rate"] == 1.0
        assert r["n_final"] == 5


def test_top_helping_partial_recognition(tmp_path):
    p = tmp_path / "ds.jsonl"
    records = []
    for i in range(10):
        in_raw = ["MLX"] if i < 8 else []
        in_final = ["MLX"]
        records.append({"vocab_terms_in_raw": in_raw, "vocab_terms_in_final": in_final})
    _write_dataset(p, records)
    results = top_helping_terms(p, limit=5)
    assert len(results) == 1
    assert results[0]["term"] == "MLX"
    assert abs(results[0]["recognition_rate"] - 0.8) < 0.01


def test_top_helping_sorted_by_rate_then_count(tmp_path):
    p = tmp_path / "ds.jsonl"
    records = [
        {"vocab_terms_in_raw": ["A", "B"], "vocab_terms_in_final": ["A", "B"]},
        {"vocab_terms_in_raw": ["A"],       "vocab_terms_in_final": ["A", "B"]},
        {"vocab_terms_in_raw": ["A"],       "vocab_terms_in_final": ["A", "B"]},
    ]
    _write_dataset(p, records)
    results = top_helping_terms(p, limit=5)
    # A appears in raw 3/3 = 1.0; B appears in raw 1/3 ≈ 0.33
    terms = [r["term"] for r in results]
    assert terms.index("A") < terms.index("B")


# ---------------------------------------------------------------------------
# dead_weight_terms
# ---------------------------------------------------------------------------

def test_dead_weight_empty_config():
    assert dead_weight_terms({}) == []


def test_dead_weight_no_zero_use_count():
    config = {
        "user_terms": {
            "en": [{"term": "MLX", "source": "auto", "added_at": "2020-01-01T00:00:00+00:00", "use_count": 3}]
        }
    }
    assert dead_weight_terms(config) == []


def test_dead_weight_too_recent():
    from datetime import datetime, timezone
    recent = (datetime.now(timezone.utc).isoformat())
    config = {
        "user_terms": {
            "en": [{"term": "new", "source": "auto", "added_at": recent, "use_count": 0}]
        }
    }
    assert dead_weight_terms(config, days=30) == []


def test_dead_weight_returns_old_zero_count():
    config = {
        "user_terms": {
            "en": [
                {"term": "old_term", "source": "auto",
                 "added_at": "2020-01-01T00:00:00+00:00", "use_count": 0},
                {"term": "used", "source": "auto",
                 "added_at": "2020-01-01T00:00:00+00:00", "use_count": 5},
            ]
        }
    }
    result = dead_weight_terms(config, days=30)
    assert len(result) == 1
    assert result[0]["term"] == "old_term"
    assert result[0]["lang"] == "en"
    assert result[0]["age_days"] > 30


def test_dead_weight_skips_manual():
    config = {
        "user_terms": {
            "ru": [
                {"term": "коллега", "source": "manual",
                 "added_at": "2020-01-01T00:00:00+00:00", "use_count": 0},
            ]
        }
    }
    assert dead_weight_terms(config, days=30) == []


def test_dead_weight_skips_inactive():
    config = {
        "user_terms": {
            "ru": [
                {"term": "term1", "source": "auto",
                 "added_at": "2020-01-01T00:00:00+00:00", "use_count": 0, "inactive": True},
            ]
        }
    }
    assert dead_weight_terms(config, days=30) == []


def test_dead_weight_sorted_by_age():
    config = {
        "user_terms": {
            "ru": [
                {"term": "newer", "source": "auto",
                 "added_at": "2024-01-01T00:00:00+00:00", "use_count": 0},
                {"term": "older", "source": "auto",
                 "added_at": "2020-01-01T00:00:00+00:00", "use_count": 0},
            ]
        }
    }
    result = dead_weight_terms(config, days=30)
    assert len(result) == 2
    assert result[0]["term"] == "older"  # oldest first


# ---------------------------------------------------------------------------
# SuggestionsPanel grouping logic (no AppKit required)
# ---------------------------------------------------------------------------

class _FakeSuggestionsPanel:
    """Stub that exposes only _get_ordered_langs for unit testing."""
    def __init__(self, items):
        self._items = items

    def _get_ordered_langs(self):
        from src.suggestions_panel import SuggestionsPanel
        sp = SuggestionsPanel.__new__(SuggestionsPanel)
        sp._items = self._items
        return sp._get_ordered_langs()


def test_ordered_langs_single():
    items = [{"lang": "ru", "count": 10}, {"lang": "ru", "count": 5}]
    panel = _FakeSuggestionsPanel(items)
    assert panel._get_ordered_langs() == ["ru"]


def test_ordered_langs_multi_sorted_by_count():
    items = [
        {"lang": "en", "count": 3},
        {"lang": "ru", "count": 10},
        {"lang": "en", "count": 5},
    ]
    panel = _FakeSuggestionsPanel(items)
    langs = panel._get_ordered_langs()
    assert langs[0] == "ru"  # 10 > 8
    assert langs[1] == "en"


def test_ordered_langs_empty():
    panel = _FakeSuggestionsPanel([])
    assert panel._get_ordered_langs() == []
