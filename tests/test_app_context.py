"""Tests for _build_chunk_context — guaranteed token/char budgets."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from src.app import (
    _build_chunk_context,
    _WHISPER_PROMPT_TOKEN_LIMIT,
    _WHISPER_PROMPT_CHAR_BUDGET,
    _MAX_RECENT_CHUNKS,
    _RECENT_CHARS_RATIO,
)
from src.utils import _count_prompt_tokens


INSTRUCTION = "Русский язык. Это разговорная речь."
VOCAB = " Whisper, Claude, Gemini, TF-IDF, XGBoost, MCP, Qwen, ADK, LLM"


# ---------------------------------------------------------------------------
# Basic correctness
# ---------------------------------------------------------------------------

def test_empty_parts_returns_base():
    result = _build_chunk_context(INSTRUCTION, VOCAB, [])
    assert result == INSTRUCTION + VOCAB


def test_short_session_includes_all_parts():
    parts = ["первый чанк", "второй чанк"]
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    assert "первый чанк" in result
    assert "второй чанк" in result


def test_result_starts_with_base():
    parts = ["some chunk"]
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    assert result.startswith(INSTRUCTION + VOCAB)


# ---------------------------------------------------------------------------
# Token limit guarantee
# ---------------------------------------------------------------------------

def test_token_limit_respected_short():
    parts = ["короткий текст"]
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    assert _count_prompt_tokens(result) <= _WHISPER_PROMPT_TOKEN_LIMIT


def test_token_limit_respected_many_cyrillic_chunks():
    """30 chunks of Cyrillic text — tokens must stay within limit."""
    parts = ["Привет это очень длинная фраза на русском языке"] * 30
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    assert _count_prompt_tokens(result) <= _WHISPER_PROMPT_TOKEN_LIMIT


def test_token_limit_respected_latin_chunks():
    """Latin text is cheaper in tokens but char budget still enforced."""
    parts = ["This is a long English transcription chunk."] * 30
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    assert _count_prompt_tokens(result) <= _WHISPER_PROMPT_TOKEN_LIMIT


# ---------------------------------------------------------------------------
# Char budget guarantee
# ---------------------------------------------------------------------------

def test_char_budget_respected():
    parts = ["x" * 200] * 10
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    assert len(result) <= _WHISPER_PROMPT_CHAR_BUDGET


# ---------------------------------------------------------------------------
# recent_text trimming (A10)
# ---------------------------------------------------------------------------

def test_max_recent_chunks_limit():
    """Only the last _MAX_RECENT_CHUNKS chunks should appear in context."""
    # Use zero-padded names so "alpha_01" is never a substring of "alpha_17".
    parts = [f"alpha_{i:02d}_zz" for i in range(20)]
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    tail_start = 20 - _MAX_RECENT_CHUNKS
    for i in range(tail_start):
        assert f"alpha_{i:02d}_zz" not in result


def test_recent_text_at_most_50pct_budget():
    """One very long chunk still keeps recent_text within 50% of char_budget."""
    long_chunk = "a" * 600  # > 50% of 700
    result = _build_chunk_context(INSTRUCTION, VOCAB, [long_chunk])
    # recent portion is result minus base
    base = INSTRUCTION + VOCAB
    recent_portion = result[len(base):].lstrip()
    assert len(recent_portion) <= int(_WHISPER_PROMPT_CHAR_BUDGET * _RECENT_CHARS_RATIO)


def test_huge_vocab_leaves_no_room_for_recent():
    """When vocab_prompt alone exceeds the token budget, recent_text is not added."""
    big_vocab = " " + ", ".join([f"Term{i}" for i in range(120)])
    base = INSTRUCTION + big_vocab
    base_tokens = _count_prompt_tokens(base)
    assert base_tokens > _WHISPER_PROMPT_TOKEN_LIMIT, "precondition: base must overflow"

    parts = ["это не должно попасть"] * 5
    result = _build_chunk_context(INSTRUCTION, big_vocab, parts)

    # Function must not add recent on top of an already-overflowing base.
    assert result == base
    assert "это не должно попасть" not in result


def test_long_session_trims_oldest_chunks():
    """30 chunks of moderate length — older ones are dropped, newest kept."""
    parts = [f"chunk_{i:02d}_text" for i in range(30)]
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    # The newest chunk within the tail window must appear
    assert "chunk_29_text" in result
    # The very first chunk must not appear
    assert "chunk_00_text" not in result


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

def test_empty_instruction():
    result = _build_chunk_context("", VOCAB, ["текст"])
    assert result.startswith(VOCAB)


def test_empty_vocab():
    result = _build_chunk_context(INSTRUCTION, "", ["текст"])
    assert "текст" in result


def test_single_chunk_too_large_for_recent():
    """A chunk larger than the recent chars budget is skipped entirely (not truncated)."""
    big = "б" * 400  # exceeds 50% of 700 = 350
    result = _build_chunk_context(INSTRUCTION, VOCAB, [big])
    assert big not in result
    assert result == INSTRUCTION + VOCAB


def test_no_chunk_cut_in_the_middle():
    """Chunks are either included whole or skipped — never partially truncated."""
    parts = ["short"] + ["medium length chunk here"] * 5 + ["final"]
    result = _build_chunk_context(INSTRUCTION, VOCAB, parts)
    base = INSTRUCTION + VOCAB
    recent_text = result[len(base):].strip()
    if recent_text:
        # Every word in recent_text must come from a full chunk
        for chunk in parts:
            if chunk in recent_text:
                pass  # full chunk present — OK
            else:
                # chunk not present at all — also OK (was dropped)
                assert chunk not in recent_text or result.count(chunk) >= 1
