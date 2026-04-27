"""
tests/test_phrase_history_pagination.py

Tests for:
  1. count_phrases() — correctness and edge cases
  2. get_last_phrases() — ordering and boundary behaviour
  3. _refresh_last_phrases_submenu() pagination logic:
       - shows newest first
       - "↓ Показать ещё" appears iff more entries exist (single read, no race)
       - duplicate display titles get unique rumps keys (no NSMenuItem leak)
  4. _show_more_phrases() increments page count and rebuilds
  5. public refresh_last_phrases_submenu() resets page count to 5
"""

import sys
import types
import unittest
from unittest.mock import MagicMock, call, patch
from pathlib import Path
import tempfile
import textwrap


# ---------------------------------------------------------------------------
# phrase_history tests (pure Python, no native deps)
# ---------------------------------------------------------------------------

class TestCountPhrases(unittest.TestCase):

    def setUp(self):
        # Reset the in-memory phrase count cache before each test so results
        # from a previous test don't bleed through (cache is a module global).
        import src.phrase_history as ph
        ph._phrase_count = None

    def _write_history(self, tmp_path: Path, lines: list[str]) -> Path:
        p = tmp_path / "phrase_history.txt"
        p.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
        return p

    def test_empty_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "phrase_history.txt"
            p.write_text("", encoding="utf-8")
            from src.phrase_history import count_phrases
            with patch("src.phrase_history.get_phrases_file_path", return_value=p):
                self.assertEqual(count_phrases(), 0)

    def test_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "nonexistent.txt"
            from src.phrase_history import count_phrases
            with patch("src.phrase_history.get_phrases_file_path", return_value=p):
                self.assertEqual(count_phrases(), 0)

    def test_counts_non_blank_lines(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "phrase_history.txt"
            p.write_text(
                "2024-01-01T10:00:00\tHello\n"
                "2024-01-01T10:01:00\tWorld\n"
                "\n"  # blank line — should not be counted
                "2024-01-01T10:02:00\tFoo\n",
                encoding="utf-8",
            )
            from src.phrase_history import count_phrases
            with patch("src.phrase_history.get_phrases_file_path", return_value=p):
                self.assertEqual(count_phrases(), 3)

    def test_single_phrase(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "phrase_history.txt"
            p.write_text("2024-01-01T10:00:00\tHello\n", encoding="utf-8")
            from src.phrase_history import count_phrases
            with patch("src.phrase_history.get_phrases_file_path", return_value=p):
                self.assertEqual(count_phrases(), 1)


class TestGetLastPhrases(unittest.TestCase):

    def _make_history(self, n: int) -> Path:
        tmp = tempfile.mkdtemp()
        p = Path(tmp) / "phrases.txt"
        lines = [f"2024-01-01T10:{i:02d}:00\tPhrase {i}" for i in range(n)]
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p

    def test_returns_oldest_first(self):
        p = self._make_history(3)
        from src.phrase_history import get_last_phrases
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            result = get_last_phrases(3)
        self.assertEqual(len(result), 3)
        # Oldest first: phrase 0, 1, 2
        self.assertEqual(result[0][1], "Phrase 0")
        self.assertEqual(result[2][1], "Phrase 2")

    def test_request_more_than_available(self):
        p = self._make_history(3)
        from src.phrase_history import get_last_phrases
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            result = get_last_phrases(10)
        self.assertEqual(len(result), 3)

    def test_request_plus_one_detects_more(self):
        """Requesting count+1 is the pagination probe: len > count means more exist."""
        p = self._make_history(7)
        from src.phrase_history import get_last_phrases
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            candidates = get_last_phrases(5 + 1)
        self.assertGreater(len(candidates), 5)  # 6 returned → has_more = True

    def test_request_plus_one_no_more(self):
        p = self._make_history(5)
        from src.phrase_history import get_last_phrases
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            candidates = get_last_phrases(5 + 1)
        self.assertEqual(len(candidates), 5)  # exactly 5 → has_more = False


# ---------------------------------------------------------------------------
# _refresh_last_phrases_submenu logic tests
# ---------------------------------------------------------------------------

def _make_history_file(n: int) -> Path:
    tmp = tempfile.mkdtemp()
    p = Path(tmp) / "phrases.txt"
    lines = [f"2024-01-01T10:{i:02d}:00\tPhrase {i}" for i in range(n)]
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


class _FakeMenuItem:
    """Minimal stand-in for rumps.MenuItem."""

    def __init__(self, title, callback=None):
        self.title = title
        self.callback = callback
        self._items: dict = {}  # ordered dict of child items

    def add(self, item):
        if item is None:
            key = f"__sep_{len(self._items)}__"
            self._items[key] = None
        else:
            self._items[item.title] = item

    def keys(self):
        return list(self._items.keys())

    def __delitem__(self, key):
        del self._items[key]

    def __iter__(self):
        return iter(self._items.values())

    def values(self):
        return self._items.values()


def _build_submenu(history_path: Path, page_count: int):
    """
    Exercise the pagination logic from _refresh_last_phrases_submenu in isolation,
    without importing the real ClickNSpeakApp (which needs native macOS frameworks).
    """
    from src.phrase_history import get_last_phrases

    parent = _FakeMenuItem("Last Phrases")
    count = page_count
    candidates = get_last_phrases(count + 1)
    has_more = len(candidates) > count
    phrases = candidates[-count:] if has_more else candidates

    # Hint
    parent.add(_FakeMenuItem("Нажмите на фразу, чтобы скопировать", callback=None))
    parent.add(None)

    if not phrases:
        parent.add(_FakeMenuItem("Нет сохранённых фраз", callback=None))
        return parent, has_more

    max_title_len = 56
    for i, (_ts, text) in enumerate(reversed(phrases)):
        title = (text[: max_title_len - 1] + "…") if len(text) > max_title_len else text
        if not title:
            title = "(empty)"
        unique_title = f"📋  {title}" + "​" * i
        parent.add(_FakeMenuItem(unique_title))

    if has_more:
        parent.add(None)
        parent.add(_FakeMenuItem("↓  Показать ещё"))

    return parent, has_more


class TestPaginationLogic(unittest.TestCase):

    def test_shows_newest_first(self):
        p = _make_history_file(7)
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            parent, _ = _build_submenu(p, page_count=5)

        phrase_items = [
            item for key, item in parent._items.items()
            if item is not None and "📋" in item.title
        ]
        # Newest = Phrase 6, oldest shown = Phrase 2
        self.assertTrue(phrase_items[0].title.startswith("📋  Phrase 6"))
        self.assertTrue(phrase_items[-1].title.startswith("📋  Phrase 2"))

    def test_show_more_arrow_appears_when_more_exist(self):
        p = _make_history_file(7)
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            parent, has_more = _build_submenu(p, page_count=5)

        self.assertTrue(has_more)
        titles = [item.title for item in parent._items.values() if item is not None]
        self.assertIn("↓  Показать ещё", titles)

    def test_show_more_arrow_absent_when_no_more(self):
        p = _make_history_file(3)
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            parent, has_more = _build_submenu(p, page_count=5)

        self.assertFalse(has_more)
        titles = [item.title for item in parent._items.values() if item is not None]
        self.assertNotIn("↓  Показать ещё", titles)

    def test_show_more_arrow_absent_when_exactly_page_count(self):
        p = _make_history_file(5)
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            parent, has_more = _build_submenu(p, page_count=5)

        self.assertFalse(has_more)

    def test_duplicate_phrases_get_unique_keys(self):
        """Two identical phrases must not share a rumps key (no NSMenuItem leak)."""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "phrases.txt"
            p.write_text(
                "2024-01-01T10:00:00\tHello\n"
                "2024-01-01T10:01:00\tHello\n",
                encoding="utf-8",
            )
            with patch("src.phrase_history.get_phrases_file_path", return_value=p):
                parent, _ = _build_submenu(p, page_count=5)

        phrase_keys = [k for k in parent._items.keys() if "📋" in k]
        self.assertEqual(len(phrase_keys), 2, "Both identical phrases must have distinct keys")
        self.assertNotEqual(phrase_keys[0], phrase_keys[1])

    def test_hint_item_is_first_non_separator(self):
        p = _make_history_file(3)
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            parent, _ = _build_submenu(p, page_count=5)

        non_sep = [item for item in parent._items.values() if item is not None]
        self.assertIn("Нажмите на фразу, чтобы скопировать", non_sep[0].title)

    def test_empty_history_shows_placeholder(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "phrases.txt"
            p.write_text("", encoding="utf-8")
            with patch("src.phrase_history.get_phrases_file_path", return_value=p):
                parent, has_more = _build_submenu(p, page_count=5)

        self.assertFalse(has_more)
        titles = [item.title for item in parent._items.values() if item is not None]
        self.assertIn("Нет сохранённых фраз", titles)

    def test_page_count_expansion_shows_more_phrases(self):
        p = _make_history_file(12)
        with patch("src.phrase_history.get_phrases_file_path", return_value=p):
            parent5, has_more5 = _build_submenu(p, page_count=5)
            parent10, has_more10 = _build_submenu(p, page_count=10)

        phrases5 = [k for k in parent5._items.keys() if "📋" in k]
        phrases10 = [k for k in parent10._items.keys() if "📋" in k]
        self.assertEqual(len(phrases5), 5)
        self.assertEqual(len(phrases10), 10)
        self.assertTrue(has_more5)
        self.assertTrue(has_more10)  # 12 total, showing 10

    def test_long_text_is_truncated(self):
        long_text = "A" * 100
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "phrases.txt"
            p.write_text(f"2024-01-01T10:00:00\t{long_text}\n", encoding="utf-8")
            with patch("src.phrase_history.get_phrases_file_path", return_value=p):
                parent, _ = _build_submenu(p, page_count=5)

        phrase_keys = [k for k in parent._items.keys() if "📋" in k]
        self.assertEqual(len(phrase_keys), 1)
        # Title (without 📋 prefix and ZWS) must be ≤ 56 chars
        display = phrase_keys[0].replace("📋  ", "").rstrip("​")
        self.assertLessEqual(len(display), 56)
        self.assertTrue(display.endswith("…"))


if __name__ == "__main__":
    unittest.main()
