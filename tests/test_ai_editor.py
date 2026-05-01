"""
tests/test_ai_editor.py

Unit tests for AiEditor.
These tests validate the module's logic and fallback behaviour WITHOUT
actually loading the LLM (which would require mlx-lm and several GB of
model weights).

Fast-path tests (no LLM):
  - refine() on an empty / whitespace-only string returns the original.
  - refine() returns original text when editor is not ready (_ready=False).
  - refine() returns original text when the LLM times out (simulated).
  - The safety guard rejects hallucinated outputs that are >2.5× the input.
  - The safety guard accepts reasonable outputs.

Integration smoke test (skipped if mlx-lm is missing):
  - AiEditor.load() does not crash when mlx-lm is available.
"""

import sys
import threading
import types
import unittest
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# Ensure the project root is on sys.path so "from src.ai_editor import …" works
# ---------------------------------------------------------------------------
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.ai_editor import AiEditor, _REFINE_TIMEOUT_SECONDS


class TestAiEditorFallbacks(unittest.TestCase):
    """Tests that exercise AiEditor without loading any actual LLM."""

    def _make_ready_editor(self) -> AiEditor:
        editor = AiEditor(model_name="fake/model")
        editor._ready = True
        editor._model = MagicMock()
        editor._tokenizer = MagicMock()
        return editor

    # ------------------------------------------------------------------
    # edge-cases: not ready, empty input
    # ------------------------------------------------------------------

    def test_refine_returns_original_when_not_ready(self):
        editor = AiEditor()
        result = editor.refine("Привет мир")
        self.assertEqual(result, "Привет мир")

    def test_refine_returns_empty_string_unchanged(self):
        editor = AiEditor()
        result = editor.refine("")
        self.assertEqual(result, "")

    def test_refine_returns_whitespace_unchanged(self):
        editor = AiEditor()
        result = editor.refine("   ")
        self.assertEqual(result, "   ")

    # ------------------------------------------------------------------
    # timeout fallback
    # ------------------------------------------------------------------

    def test_refine_falls_back_on_timeout(self):
        """When the LLM thread hangs, refine() should return the original."""
        editor = self._make_ready_editor()

        def _slow_call(text):
            # Simulate a stalled LLM (sleep longer than the timeout)
            threading.Event().wait(_REFINE_TIMEOUT_SECONDS + 5)
            return "should never be returned"  # pragma: no cover

        editor._call_llm = _slow_call
        result = editor.refine("тест таймаут")
        self.assertEqual(result, "тест таймаут")

    # ------------------------------------------------------------------
    # safety guard
    # ------------------------------------------------------------------

    def test_safety_guard_rejects_overly_long_output(self):
        editor = self._make_ready_editor()
        short_input = "ну это текст"
        # Simulate an LLM that returns something 3× longer (hallucination)
        long_output = short_input * 10
        editor._call_llm = lambda t, **kw: long_output
        result = editor.refine(short_input)
        self.assertEqual(result, short_input)

    def test_safety_guard_accepts_reasonable_output(self):
        editor = self._make_ready_editor()
        raw = "привет это тест короче вот"
        cleaned = "Привет. Это тест."
        editor._call_llm = lambda t, **kw: cleaned
        result = editor.refine(raw)
        self.assertEqual(result, cleaned)

    # ------------------------------------------------------------------
    # normal operation
    # ------------------------------------------------------------------

    def test_refine_strips_filler_words_via_llm(self):
        """Verify that a mocked LLM result is returned correctly."""
        editor = self._make_ready_editor()
        raw = "ну вот это короче тест"
        polished = "Это тест."
        editor._call_llm = lambda t, **kw: polished
        result = editor.refine(raw)
        self.assertEqual(result, polished)

    def test_refine_returns_original_if_llm_returns_empty(self):
        editor = self._make_ready_editor()
        raw = "это некий текст"
        editor._call_llm = lambda t, **kw: ""
        result = editor.refine(raw)
        self.assertEqual(result, raw)

    def test_refine_returns_original_if_llm_raises(self):
        editor = self._make_ready_editor()
        raw = "критическая ошибка"

        def _crash(_, **kw):
            raise RuntimeError("LLM exploded")

        editor._call_llm = _crash
        result = editor.refine(raw)
        self.assertEqual(result, raw)

    # ------------------------------------------------------------------
    # last_refine_status
    # ------------------------------------------------------------------

    def test_status_disabled_when_not_ready(self):
        editor = AiEditor()
        editor.refine("любой текст")
        self.assertEqual(editor.last_refine_status, AiEditor.REFINE_STATUS_DISABLED)

    def test_status_ok_on_successful_refinement(self):
        editor = self._make_ready_editor()
        editor._call_llm = lambda t, **kw: "Исправленный текст."
        editor.refine("исправленный текст")
        self.assertEqual(editor.last_refine_status, AiEditor.REFINE_STATUS_OK)

    def test_status_unchanged_when_llm_returns_same(self):
        editor = self._make_ready_editor()
        text = "Уже хороший текст."
        editor._call_llm = lambda t, **kw: text
        editor.refine(text)
        self.assertEqual(editor.last_refine_status, AiEditor.REFINE_STATUS_UNCHANGED)

    def test_status_timeout_on_slow_llm(self):
        editor = self._make_ready_editor()

        def _slow_call(text, **kw):
            threading.Event().wait(_REFINE_TIMEOUT_SECONDS + 5)
            return "никогда не вернётся"  # pragma: no cover

        editor._call_llm = _slow_call
        editor.refine("таймаут тест")
        self.assertEqual(editor.last_refine_status, AiEditor.REFINE_STATUS_TIMEOUT)

    def test_status_error_on_llm_exception(self):
        editor = self._make_ready_editor()
        editor._call_llm = lambda t, **kw: (_ for _ in ()).throw(RuntimeError("crash"))
        editor.refine("ошибка теста")
        self.assertEqual(editor.last_refine_status, AiEditor.REFINE_STATUS_ERROR)

    def test_status_skipped_when_lock_held(self):
        editor = self._make_ready_editor()
        editor._lock.acquire()  # simulate another call in progress
        try:
            editor.refine("занято")
            self.assertEqual(editor.last_refine_status, AiEditor.REFINE_STATUS_SKIPPED)
        finally:
            editor._lock.release()


# ---------------------------------------------------------------------------
# Integration smoke-test (only runs if mlx-lm is installed)
# ---------------------------------------------------------------------------

@unittest.skipUnless(
    __import__("importlib").util.find_spec("mlx_lm") is not None,
    "mlx-lm is not installed — skipping integration smoke test",
)
class TestAiEditorIntegration(unittest.TestCase):
    """Smoke test that actually imports mlx_lm and calls cache check."""

    def test_load_does_not_crash(self):
        editor = AiEditor(model_name="mlx-community/Qwen2.5-7B-Instruct-4bit")
        # Verify object creation is correct (we do NOT call load() to avoid network)
        self.assertFalse(editor.is_ready())
        self.assertEqual(editor.model_name, "mlx-community/Qwen2.5-7B-Instruct-4bit")

    def test_is_model_cached_returns_bool(self):
        """is_model_cached() must always return a bool, never raise."""
        editor = AiEditor(model_name="mlx-community/Qwen2.5-7B-Instruct-4bit")
        result = editor.is_model_cached()
        self.assertIsInstance(result, bool)

    def test_is_model_cached_false_for_nonexistent_model(self):
        """A clearly fake model name must return False, not raise."""
        editor = AiEditor(model_name="mlx-community/this-model-does-not-exist-xyz123")
        result = editor.is_model_cached()
        self.assertFalse(result)

    def test_load_does_not_download_when_model_missing(self):
        """load() must return quickly without downloading when model is not cached."""
        import time
        editor = AiEditor(model_name="mlx-community/this-model-does-not-exist-xyz123")
        start = time.time()
        editor.load()  # Should return fast, not hang downloading
        elapsed = time.time() - start
        self.assertFalse(editor.is_ready())
        self.assertLess(elapsed, 10.0, "load() should not block for more than 10s")


if __name__ == "__main__":
    unittest.main()
