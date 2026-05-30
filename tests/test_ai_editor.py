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
import tempfile
import types
import unittest
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# Ensure the project root is on sys.path so "from src.ai_editor import …" works
# ---------------------------------------------------------------------------
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.ai_editor import (
    AiEditor,
    ExternalApiEditor,
    GeminiEditor,
    _REFINE_TIMEOUT_SECONDS,
    _build_api_editor_system_prompt,
    _build_system_prompt,
)
from src.vocab_provider import collect_known_terms, collect_misrecognitions


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
        import time as _time
        editor = self._make_ready_editor()
        # Simulate a recently-used editor so the normal 8s timeout applies,
        # not the cold-start 25s timeout (which would let the slow call succeed).
        editor._last_refine_at = _time.monotonic()

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


class _DummyApiEditor(ExternalApiEditor):
    def __init__(self):
        super().__init__(model_name="dummy/model")

    def load(self) -> None:
        self._ready = True

    def is_ready(self) -> bool:
        return self._ready

    def refine(self, text: str, languages=None, known_terms=None, misrecognitions=None) -> str:
        _ = self._get_system_prompt(languages, known_terms, misrecognitions)
        return text

    def refine_file_text(self, text: str, languages=None, known_terms=None, misrecognitions=None) -> str:
        _ = self._get_system_prompt(languages, known_terms, misrecognitions)
        return text


class TestExternalApiEditorPrompts(unittest.TestCase):
    def test_api_prompt_without_dict_matches_base_prompt(self):
        self.assertEqual(
            _build_api_editor_system_prompt(["ru", "en"]),
            _build_system_prompt(["ru", "en"]),
        )

    def test_api_prompt_with_known_terms(self):
        prompt = _build_api_editor_system_prompt(["en"], known_terms=["GitHub", "PCA"])
        self.assertIn("KNOWN TERMS", prompt)
        self.assertIn("GitHub, PCA", prompt)

    def test_api_prompt_with_misrecognitions(self):
        prompt = _build_api_editor_system_prompt(
            ["en"], misrecognitions=[("git hub", "GitHub"), ("piton", "Python")]
        )
        self.assertIn("COMMON MISRECOGNITIONS", prompt)
        self.assertIn('"git hub" -> "GitHub"', prompt)
        self.assertIn('"piton" -> "Python"', prompt)

    def test_external_api_editor_cannot_be_instantiated(self):
        with self.assertRaises(TypeError):
            ExternalApiEditor("model")  # type: ignore[abstract]

    def test_prompt_cache_reused_for_same_inputs(self):
        editor = _DummyApiEditor()
        with patch("src.ai_editor._build_api_editor_system_prompt", wraps=_build_api_editor_system_prompt) as mocked:
            editor._get_system_prompt(["en"], ["GitHub"], [("piton", "Python")])
            editor._get_system_prompt(["en"], ["GitHub"], [("piton", "Python")])
            self.assertEqual(mocked.call_count, 1)

    def test_prompt_cache_invalidates_when_inputs_change(self):
        editor = _DummyApiEditor()
        with patch("src.ai_editor._build_api_editor_system_prompt", wraps=_build_api_editor_system_prompt) as mocked:
            editor._get_system_prompt(["en"], ["GitHub"], [("piton", "Python")])
            editor._get_system_prompt(["en"], ["GitHub", "MLX"], [("piton", "Python")])
            self.assertEqual(mocked.call_count, 2)

    def test_qwen_path_accepts_interface_args_without_dictionary_effect(self):
        editor = AiEditor(model_name="fake/model")
        editor._ready = True
        editor._model = MagicMock()
        editor._tokenizer = MagicMock()
        editor._call_llm = lambda text, **kwargs: "Qwen output"
        result = editor.refine(
            "input text",
            languages=["en"],
            known_terms=["GitHub"],
            misrecognitions=[("piton", "Python")],
        )
        self.assertEqual(result, "Qwen output")

    def test_qwen_prompt_uses_ukrainian_name_and_fillers_for_uk_code(self):
        prompt = _build_system_prompt(["uk", "de"])
        self.assertIn("Ukrainian and German", prompt)
        self.assertIn("'типу'", prompt)
        self.assertIn("'äh'", prompt)

    def test_gemini_token_estimator_treats_uk_as_cyrillic(self):
        text = (
            "це тестовий український текст для оцінки токенів "
            "який достатньо довгий щоб уникнути мінімального порогу "
        ) * 8
        self.assertGreater(
            GeminiEditor._estimate_tokens(text, ["uk"]),
            GeminiEditor._estimate_tokens(text, ["de"]),
        )


class TestVocabProvider(unittest.TestCase):
    def test_known_terms_capped_at_50_with_priority(self):
        manual = [{"term": f"Manual{i}", "source": "manual", "use_count": 1} for i in range(30)]
        auto = [{"term": f"Auto{i}", "source": "auto", "use_count": 100 - i} for i in range(80)]
        config = {"primary_language": "en", "user_terms": {"en": manual + auto}}
        terms = collect_known_terms(config, ["en"])
        self.assertEqual(len(terms), 50)
        self.assertTrue(all(term.startswith("Manual") for term in terms[:30]))

    def test_term_sanitization(self):
        config = {
            "primary_language": "en",
            "user_terms": {"en": [{"term": "Git\n\"Hub\"", "source": "manual", "use_count": 1}]},
        }
        terms = collect_known_terms(config, ["en"])
        self.assertEqual(terms, ["Git 'Hub"])

    def test_misrecognitions_capped_at_30_and_min_count(self):
        pairs = [
            {"from": f"old {i}", "to": f"new {i}", "count": 3 + (40 - i)}
            for i in range(40)
        ]
        index_payload = {"replacement_pairs": {"latin": pairs, "cyrillic": []}}
        with tempfile.TemporaryDirectory() as tmp:
            idx_path = os.path.join(tmp, "corrections.json")
            with open(idx_path, "w", encoding="utf-8") as f:
                import json

                json.dump(index_payload, f)
            with patch("src.vocab_provider.get_corrections_file_path", return_value=__import__("pathlib").Path(idx_path)):
                result = collect_misrecognitions(["en"])
        self.assertEqual(len(result), 30)

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
