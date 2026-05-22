"""Minimal i18n engine for Click-n-speak.

Usage:
    from . import i18n
    i18n.load("ru")          # call once at startup (or after language change)
    i18n.t("menu.history_hint")
    i18n.t("toast.added", term="MLX")
    i18n.plural("terms.term_word", 3)   # → "термина" in Russian
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

_logger = logging.getLogger(__name__)

_LOCALES_DIR = Path(__file__).resolve().parent.parent / "locales"
SUPPORTED_LANGS: frozenset[str] = frozenset({"ru", "en", "uk", "de", "es", "fr"})
_SLAVIC: frozenset[str] = frozenset({"ru", "uk"})

_lang: str = "en"
_strings: dict[str, object] = {}
_fallback: dict[str, object] = {}


def load(lang: str) -> None:
    """Load locale file for *lang*. Falls back to English for unknown codes."""
    global _lang, _strings, _fallback
    code = (lang or "en").lower().strip()
    if code not in SUPPORTED_LANGS:
        code = "en"
    _lang = code
    _strings = _load_file(code)
    _fallback = _load_file("en") if code != "en" else {}


def _load_file(lang: str) -> dict[str, object]:
    path = _LOCALES_DIR / f"{lang}.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _logger.warning("Locale file not found: %s", path)
        return {}
    except Exception as exc:
        _logger.error("Failed to load locale %s: %s", lang, exc)
        return {}


def current() -> str:
    """Return the currently loaded language code (e.g. 'ru')."""
    return _lang


def t(key: str, **kwargs: object) -> str:
    """Return translated string for *key*, formatted with *kwargs*.

    Falls back to English, then to the key itself — never raises.
    """
    raw = _strings.get(key) or _fallback.get(key) or key
    if not isinstance(raw, str):
        return key
    if not kwargs:
        return raw
    try:
        return raw.format(**kwargs)
    except (KeyError, ValueError):
        return raw


def plural(key: str, n: int) -> str:
    """Return the correct plural form from an array stored at *key*.

    Locale files store plural arrays as JSON arrays, e.g.:
      RU/UK:  ["термин", "термина", "терминов"]   (3 forms)
      others: ["term", "terms"]                   (2 forms)
    """
    forms = _strings.get(key) or _fallback.get(key)
    if not isinstance(forms, list) or not forms:
        return str(n)
    idx = _plural_idx(n)
    return forms[min(idx, len(forms) - 1)]


def _plural_idx(n: int) -> int:
    """Return plural form index: 0=one, 1=few, 2=many (slavic) or 0=one, 1=other."""
    if _lang in _SLAVIC:
        if n % 10 == 1 and n % 100 != 11:
            return 0
        if 2 <= n % 10 <= 4 and (n % 100 < 10 or n % 100 >= 20):
            return 1
        return 2
    return 0 if n == 1 else 1
