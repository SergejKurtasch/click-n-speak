import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from src.app import _join_chunks


def test_single_chunk_unchanged():
    assert _join_chunks(["Привет мир."]) == "Привет мир."


def test_empty_list():
    assert _join_chunks([]) == ""


def test_period_before_lowercase_removed():
    # Whisper put a period at end of chunk 1, but chunk 2 continues the sentence
    result = _join_chunks(["Посмотри текущую ветку.", "мне нужно переключиться"])
    assert result == "Посмотри текущую ветку мне нужно переключиться"


def test_period_before_uppercase_kept():
    # Legitimate sentence boundary — period stays
    result = _join_chunks(["Первое предложение.", "Второе предложение."])
    assert result == "Первое предложение. Второе предложение."


def test_exclamation_before_lowercase_removed():
    result = _join_chunks(["Стоп!", "подожди секунду"])
    assert result == "Стоп подожди секунду"


def test_question_mark_before_uppercase_kept():
    result = _join_chunks(["Как дела?", "Всё хорошо."])
    assert result == "Как дела? Всё хорошо."


def test_no_trailing_punctuation_joined_normally():
    result = _join_chunks(["первая часть", "вторая часть"])
    assert result == "первая часть вторая часть"


def test_three_chunks_mixed():
    # chunk1 ends with period, chunk2 starts lowercase, chunk2 ends with period, chunk3 uppercase
    result = _join_chunks(["коммиты свежие.", "когда последний раз", "Когда был коммит?"])
    assert result == "коммиты свежие когда последний раз Когда был коммит?"


def test_strips_leading_trailing_whitespace():
    # Only outer whitespace of the full result is stripped
    result = _join_chunks(["привет", "мир"])
    assert result == "привет мир"
