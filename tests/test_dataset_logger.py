"""Tests for dataset_logger: _find_terms and append_to_dataset record shape."""

import json
import tempfile
from pathlib import Path

import pytest

from src.dataset_logger import _find_terms, append_to_dataset


# ---------------------------------------------------------------------------
# _find_terms
# ---------------------------------------------------------------------------

def test_find_terms_case_insensitive():
    result = _find_terms("I use MLX for inference", ["MLX"])
    assert result == ["mlx"]


def test_find_terms_multiple():
    terms = ["MLX", "GitHub", "PCA"]
    result = _find_terms("Using MLX and GitHub together", terms)
    assert "mlx" in result
    assert "github" in result
    assert "pca" not in result


def test_find_terms_punctuation():
    result = _find_terms("Я люблю C++ программирование", ["C++"])
    assert result == ["c++"]


def test_find_terms_empty_text():
    assert _find_terms("", ["MLX"]) == []


def test_find_terms_empty_terms():
    assert _find_terms("some text", []) == []


def test_find_terms_no_match():
    assert _find_terms("totally unrelated", ["MLX"]) == []


def test_find_terms_cyrillic():
    result = _find_terms("нейросеть помогает в работе", ["нейросеть"])
    assert result == ["нейросеть"]


def test_find_terms_multi_word_found():
    result = _find_terms("we use machine learning every day", ["machine learning"])
    assert result == ["machine learning"]


def test_find_terms_multi_word_case_insensitive():
    result = _find_terms("We use Machine Learning every day", ["machine learning"])
    assert result == ["machine learning"]


def test_find_terms_multi_word_not_found():
    result = _find_terms("we use deep learning every day", ["machine learning"])
    assert result == []


def test_find_terms_multi_word_cyrillic():
    result = _find_terms("нейронные сети решают много задач", ["нейронные сети"])
    assert result == ["нейронные сети"]


# ---------------------------------------------------------------------------
# append_to_dataset record shape
# ---------------------------------------------------------------------------

def test_record_shape_has_new_fields():
    with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as f:
        path = f.name

    append_to_dataset(
        raw_text="MLX transcription",
        ai_text="MLX transcription.",
        user_final_text="MLX transcription.",
        ai_status="ok",
        dataset_path=path,
        lang="en",
        user_terms_for_lang=["MLX", "GitHub"],
        prompt_hash="abc123def456",
    )

    record = json.loads(Path(path).read_text(encoding="utf-8").strip())
    assert "lang" in record
    assert record["lang"] == "en"
    assert "prompt_hash" in record
    assert record["prompt_hash"] == "abc123def456"
    assert "vocab_terms_in_raw" in record
    assert "vocab_terms_in_final" in record
    assert "mlx" in record["vocab_terms_in_raw"]
    assert "mlx" in record["vocab_terms_in_final"]


def test_record_shape_without_new_fields():
    """Calling without keyword args produces empty/None new fields — old callers not broken."""
    with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as f:
        path = f.name

    append_to_dataset(
        raw_text="some text",
        ai_text=None,
        user_final_text="some text",
        dataset_path=path,
    )

    record = json.loads(Path(path).read_text(encoding="utf-8").strip())
    assert record["lang"] is None
    assert record["prompt_hash"] is None
    assert record["vocab_terms_in_raw"] == []
    assert record["vocab_terms_in_final"] == []


def test_record_preserves_existing_fields():
    with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as f:
        path = f.name

    append_to_dataset(
        raw_text="raw",
        ai_text="edited",
        user_final_text="final",
        ai_status="ok",
        dataset_path=path,
    )

    record = json.loads(Path(path).read_text(encoding="utf-8").strip())
    assert record["raw_whisper"] == "raw"
    assert record["ai_edited"] == "edited"
    assert record["user_final"] == "final"
    assert record["ai_status"] == "ok"
    assert "timestamp" in record
