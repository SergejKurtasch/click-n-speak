"""Tests for detect_term_script, _is_valid_term (multi-word), and add_term_to_user_terms."""

import pytest

from src.utils import detect_term_script, target_lang_for_script_bucket
from src.preview_panel import _is_valid_term
from src.vocab_provider import add_term_to_user_terms


# ---------------------------------------------------------------------------
# detect_term_script
# ---------------------------------------------------------------------------

def test_detect_latin():
    assert detect_term_script("GitHub") == "latin"


def test_detect_cyrillic():
    assert detect_term_script("нейросеть") == "cyrillic"


def test_detect_latin_multiword():
    assert detect_term_script("machine learning") == "latin"


def test_detect_cyrillic_multiword():
    assert detect_term_script("нейронные сети") == "cyrillic"


def test_detect_mixed_prefers_dominant():
    # "TF-IDF для текста" — 3 Cyrillic word chars vs 5 Latin chars
    # "для" = 3 cyrillic, "текста" = 6 cyrillic, "TF" = 2 latin, "IDF" = 3 latin
    assert detect_term_script("TF-IDF для текста") == "cyrillic"


def test_detect_pure_latin_phrase():
    assert detect_term_script("GitHub Actions") == "latin"


def test_detect_digits_only_returns_none():
    assert detect_term_script("123") is None


def test_detect_empty_returns_none():
    assert detect_term_script("") is None


def test_detect_tied_returns_none():
    # Equal Latin and Cyrillic counts → None
    assert detect_term_script("ab аб") is None


# ---------------------------------------------------------------------------
# Script-to-lang routing: detect_term_script + target_lang_for_script_bucket
# ---------------------------------------------------------------------------

def test_latin_term_routes_to_en_when_primary_ru():
    script = detect_term_script("GitHub")
    primary, additional = "ru", ["en"]
    lang = target_lang_for_script_bucket(script, primary, additional)
    assert lang == "en"


def test_cyrillic_term_routes_to_primary_ru():
    script = detect_term_script("нейросеть")
    primary, additional = "ru", ["en"]
    lang = target_lang_for_script_bucket(script, primary, additional)
    assert lang == "ru"


def test_latin_term_fallback_to_primary_when_no_latin_additional():
    script = detect_term_script("GitHub")
    primary, additional = "ru", []  # no English in config
    lang = target_lang_for_script_bucket(script, primary, additional)
    assert lang == "ru"  # graceful fallback, not crash


# ---------------------------------------------------------------------------
# _is_valid_term — single-word (regression)
# ---------------------------------------------------------------------------

def test_valid_single_word():
    assert _is_valid_term("MLX") is True


def test_valid_term_with_symbols():
    assert _is_valid_term("C++") is True
    assert _is_valid_term("TF-IDF") is True
    assert _is_valid_term("node.js") is True


def test_stoplist_word_rejected():
    assert _is_valid_term("the") is False


def test_single_char_rejected():
    assert _is_valid_term("a") is False


def test_pure_digits_rejected():
    assert _is_valid_term("123") is False


# ---------------------------------------------------------------------------
# _is_valid_term — multi-word (new)
# ---------------------------------------------------------------------------

def test_two_word_phrase():
    assert _is_valid_term("machine learning") is True


def test_two_word_cyrillic():
    assert _is_valid_term("нейронные сети") is True


def test_three_word_phrase():
    assert _is_valid_term("reinforcement learning algorithm") is True


def test_four_word_phrase_allowed():
    assert _is_valid_term("large language model inference") is True


def test_five_words_rejected():
    assert _is_valid_term("a b c d e") is False


def test_phrase_with_punctuation_in_word():
    assert _is_valid_term("C++ programming") is True


def test_phrase_trailing_punctuation_rejected():
    # "hello!" — exclamation is not a term char
    assert _is_valid_term("hello world!!!") is False


def test_phrase_leading_digit_word_rejected():
    # word starting with digit is not a valid term start
    assert _is_valid_term("3D modeling") is False


def test_stoplist_not_applied_to_multiword():
    # "the way" — "the" is stoplist but as a phrase it should be allowed
    assert _is_valid_term("the way") is True


# ---------------------------------------------------------------------------
# add_term_to_user_terms — multi-word storage
# ---------------------------------------------------------------------------

def _make_cfg():
    return {"schema_version": 5, "user_terms": {"en": [], "ru": []}}


def test_add_multiword_term():
    cfg = _make_cfg()
    result = add_term_to_user_terms(cfg, "en", "machine learning")
    assert result is True
    assert cfg["user_terms"]["en"][0]["term"] == "machine learning"


def test_add_multiword_deduplication():
    cfg = _make_cfg()
    add_term_to_user_terms(cfg, "en", "machine learning")
    result = add_term_to_user_terms(cfg, "en", "Machine Learning")
    assert result is False  # case-insensitive dedupe


def test_add_cyrillic_multiword():
    cfg = _make_cfg()
    result = add_term_to_user_terms(cfg, "ru", "нейронные сети")
    assert result is True
    assert cfg["user_terms"]["ru"][0]["term"] == "нейронные сети"
