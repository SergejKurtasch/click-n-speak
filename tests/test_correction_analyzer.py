import json

import pytest

from src.correction_analyzer import get_correction_candidates, update_corrections_index


def _write_jsonl(path, records):
    with path.open("w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def _base_record(ts: str, raw: str, user: str, ai: str | None = None) -> dict:
    return {
        "timestamp": ts,
        "raw_whisper": raw,
        "ai_edited": ai,
        "ai_status": "ok" if ai else None,
        "user_final": user,
    }


def test_pure_insert_collected(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [
            _base_record(
                "2026-05-07T12:00:00+00:00",
                raw="hello world",
                ai="hello world",
                user="hello PCA world",
            )
        ],
    )

    out = update_corrections_index(dataset_path=dataset, index_path=index)
    assert out["inserted_terms"]["latin"]["pca"]["term"] == "PCA"
    assert out["inserted_terms"]["latin"]["pca"]["count"] == 1


def test_replacement_pair_collected(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [_base_record("2026-05-07T12:00:00+00:00", raw="hello питон", user="hello Python")],
    )

    out = update_corrections_index(dataset_path=dataset, index_path=index)
    pairs = out["replacement_pairs"]["latin"]
    assert any(p["from"] == "питон" and p["to"] == "Python" for p in pairs)


def test_filler_words_filtered(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [
            _base_record("2026-05-07T12:00:00+00:00", raw="hello world", user="hello the world"),
            _base_record("2026-05-07T12:01:00+00:00", raw="value", user="value 2024"),
        ],
    )
    out = update_corrections_index(dataset_path=dataset, index_path=index)
    assert out["inserted_terms"]["latin"] == {}


def test_incremental_update(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [_base_record("2026-05-07T12:00:00+00:00", raw="hello", user="hello PCA")],
    )
    first = update_corrections_index(dataset_path=dataset, index_path=index)
    assert first["inserted_terms"]["latin"]["pca"]["count"] == 1

    _write_jsonl(
        dataset,
        [
            _base_record("2026-05-07T12:00:00+00:00", raw="hello", user="hello PCA"),
            _base_record("2026-05-07T12:01:00+00:00", raw="hello", user="hello PCA"),
        ],
    )
    second = update_corrections_index(dataset_path=dataset, index_path=index)
    assert second["inserted_terms"]["latin"]["pca"]["count"] == 2


def test_count_aggregates(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [
            _base_record("2026-05-07T12:00:00+00:00", raw="a", user="a MLX"),
            _base_record("2026-05-07T12:01:00+00:00", raw="a", user="a MLX"),
            _base_record("2026-05-07T12:02:00+00:00", raw="a", user="a MLX"),
        ],
    )
    out = update_corrections_index(dataset_path=dataset, index_path=index)
    assert out["inserted_terms"]["latin"]["mlx"]["count"] == 3


def test_long_replacement_skipped(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [
            _base_record(
                "2026-05-07T12:00:00+00:00",
                raw="one two three four five six",
                user="alpha beta gamma delta epsilon zeta",
            )
        ],
    )
    out = update_corrections_index(dataset_path=dataset, index_path=index)
    assert out["replacement_pairs"]["latin"] == []


def test_min_correction_count(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [_base_record("2026-05-07T12:00:00+00:00", raw="x", user="x PCA")],
    )
    idx = update_corrections_index(dataset_path=dataset, index_path=index)
    candidates = get_correction_candidates(
        idx,
        existing_lower_by_lang={"en": set(), "ru": set()},
        skipped_lower_by_lang={"en": {}, "ru": {}},
        current_phrase_count=100,
        min_correction_count=2,
    )
    assert candidates == {}


def test_existing_terms_excluded(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [
            _base_record("2026-05-07T12:00:00+00:00", raw="x", user="x PCA"),
            _base_record("2026-05-07T12:01:00+00:00", raw="x", user="x PCA"),
        ],
    )
    idx = update_corrections_index(dataset_path=dataset, index_path=index)
    candidates = get_correction_candidates(
        idx,
        existing_lower_by_lang={"en": {"pca"}, "ru": set()},
        skipped_lower_by_lang={"en": {}, "ru": {}},
        current_phrase_count=100,
    )
    assert candidates == {}


def test_cooldown_respected(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [
            _base_record("2026-05-07T12:00:00+00:00", raw="x", user="x PCA"),
            _base_record("2026-05-07T12:01:00+00:00", raw="x", user="x PCA"),
        ],
    )
    idx = update_corrections_index(dataset_path=dataset, index_path=index)
    candidates = get_correction_candidates(
        idx,
        existing_lower_by_lang={"en": set(), "ru": set()},
        skipped_lower_by_lang={"en": {"pca": 95}, "ru": {}},
        current_phrase_count=100,
        cooldown_phrases=10,
    )
    assert candidates == {}


def test_migrate_v1_to_v2(tmp_path):
    """Legacy corrections.json (v1 keys en/ru) loads as v2 (latin/cyrillic) in memory."""
    dataset = tmp_path / "dataset.jsonl"
    dataset.write_text("", encoding="utf-8")
    index = tmp_path / "corrections.json"
    index.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "last_processed_ts": None,
                "processed_rows": 0,
                "inserted_terms": {
                    "en": {
                        "pca": {
                            "term": "PCA",
                            "count": 5,
                            "first_seen": "2026-05-01T12:00:00+00:00",
                            "last_seen": "2026-05-07T12:00:00+00:00",
                        }
                    }
                },
                "replacement_pairs": {
                    "ru": [
                        {
                            "from": "питон",
                            "to": "Python",
                            "count": 3,
                            "last_seen": "2026-05-07T12:00:00+00:00",
                        }
                    ]
                },
            }
        ),
        encoding="utf-8",
    )
    out = update_corrections_index(dataset_path=dataset, index_path=index)
    assert out["schema_version"] == 3
    assert out["inserted_terms"]["latin"]["pca"]["term"] == "PCA"
    assert "en" not in out["inserted_terms"]
    assert out["replacement_pairs"]["cyrillic"][0]["from"] == "питон"


def test_atomic_write_failure_keeps_previous_file(tmp_path, monkeypatch):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    index.write_text(json.dumps({"schema_version": 1, "last_processed_ts": None, "processed_rows": 0, "inserted_terms": {"en": {}, "ru": {}}, "replacement_pairs": {"en": [], "ru": []}}), encoding="utf-8")
    _write_jsonl(dataset, [_base_record("2026-05-07T12:00:00+00:00", raw="x", user="x PCA")])

    def _boom(*args, **kwargs):
        raise OSError("replace failed")

    monkeypatch.setattr("src.correction_analyzer.write_json_atomic", _boom)
    with pytest.raises(OSError):
        update_corrections_index(dataset_path=dataset, index_path=index)

    # File still contains valid JSON (previous snapshot, not partial content).
    data = json.loads(index.read_text(encoding="utf-8"))
    assert data["schema_version"] == 1


def test_no_double_count_on_punct_only_ai_edit(tmp_path):
    """When ai_edited differs from raw_whisper only in punctuation/casing, MLX is counted once."""
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    # raw = "hello" (no punct), ai_edited = "Hello." (added capitalisation + period only)
    # user added "MLX" — it should be counted once, not twice.
    _write_jsonl(
        dataset,
        [_base_record("2026-05-07T12:00:00+00:00", raw="hello", ai="Hello.", user="Hello. MLX")],
    )
    out = update_corrections_index(dataset_path=dataset, index_path=index)
    assert out["inserted_terms"]["latin"].get("mlx", {}).get("count", 0) == 1


def test_trailing_punctuation_uses_same_inserted_key(tmp_path):
    dataset = tmp_path / "dataset.jsonl"
    index = tmp_path / "corrections.json"
    _write_jsonl(
        dataset,
        [
            _base_record("2026-05-07T12:00:00+00:00", raw="hello", user="hello GitHub."),
            _base_record("2026-05-07T12:01:00+00:00", raw="hello", user="hello GitHub"),
        ],
    )
    out = update_corrections_index(dataset_path=dataset, index_path=index)
    assert out["inserted_terms"]["latin"]["github"]["count"] == 2
    assert out["inserted_terms"]["latin"]["github"]["term"] == "GitHub"
