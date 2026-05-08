import json
from pathlib import Path

from src.metrics import (
    _edit_score_char,
    append_metrics_history,
    compute_metrics,
    load_metrics_history,
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
