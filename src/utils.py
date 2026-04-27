import json
import logging
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from typing import Optional

# Project root (parent of src/)
ROOT = Path(__file__).resolve().parent.parent


def _get_app_bundle() -> str | None:
    """Return the .app bundle path when running as a bundled app, else None.

    Checks CLICK_N_SPEAK_APP env var first (set by the C launcher), then falls
    back to detecting py2app via sys.frozen (set by py2app at runtime).
    """
    env = os.environ.get("CLICK_N_SPEAK_APP")
    if env:
        return env
    if getattr(sys, "frozen", False):
        # py2app: sys.executable = .../Click-n-speak.app/Contents/MacOS/Click-n-speak
        return os.path.abspath(os.path.join(sys.executable, "../../.."))
    return None


def relaunch_app() -> bool:
    """Relaunch the .app bundle in a fresh process and exit the current one.

    Returns False if not running from a bundle (dev mode) so caller can skip.
    """
    import signal as _signal
    bundle = _get_app_bundle()
    if not bundle:
        return False
    # Fork a helper that waits for this process to exit then opens a new instance.
    # `open -n` forces a new instance even if bundle is still in the LaunchServices DB.
    # start_new_session=True puts the helper in its own session so it survives our exit.
    import shlex as _shlex
    subprocess.Popen(
        ["sh", "-c", f"sleep 1 && open -n {_shlex.quote(bundle)}"],
        start_new_session=True,
    )
    # Kill the entire process group (main process + all child processes such as the
    # transcriber). os._exit(0) only kills the main process; os.killpg ensures orphaned
    # child processes (daemon=True multiprocessing children whose atexit cleanup is
    # bypassed by os._exit) are also killed immediately.
    # The helper shell above is in its own session (start_new_session=True) and is
    # unaffected by killpg on our process group.
    try:
        os.killpg(os.getpgrp(), _signal.SIGKILL)
    except Exception:
        os._exit(0)

# Application Support dir when running from .app (set by launcher)
APPLICATION_SUPPORT_DIR = Path(os.path.expanduser("~/Library/Application Support/Click-n-speak"))

# macOS system sounds used for recording feedback (configurable via play_sound argument)
SOUND_RECORDING_START = "/System/Library/Sounds/Tink.aiff"
SOUND_RECORDING_STOP = "/System/Library/Sounds/Pop.aiff"


def get_menu_icon_path() -> Path:
    """Return the path to the PNG icon used in the menu bar."""
    app_bundle = _get_app_bundle()
    if app_bundle:
        bundle_icon = Path(app_bundle) / "Contents" / "Resources" / "CnS.png"
        if bundle_icon.exists():
            return bundle_icon

    # Fallback: project root when running from source
    return ROOT / "assets" / "CnS.png"


def get_menubar_icon_path(state: str = "idle") -> Path:
    """Return path to a menubar PNG icon for the given state ('idle'|'recording'|'processing').

    Prefers *Template.png (black icons that adapt to dark/light mode) over plain *.png.
    """
    app_bundle = _get_app_bundle()
    if app_bundle:
        base = Path(app_bundle) / "Contents" / "Resources" / "icons" / "menubar"
        for suffix in (f"{state}Template.png", f"{state}.png"):
            p = base / suffix
            if p.exists():
                return p
    for suffix in (f"{state}Template.png", f"{state}.png"):
        p = ROOT / "assets" / "icons" / "menubar" / suffix
        if p.exists():
            return p
    return get_menu_icon_path()


def get_menu_item_icon_path(name: str) -> Path | None:
    """Return path to a menu-item PNG icon, or None if not found.

    Prefers *Template.png (black icons that adapt to dark/light mode) over plain *.png.
    """
    app_bundle = _get_app_bundle()
    if app_bundle:
        base = Path(app_bundle) / "Contents" / "Resources" / "icons" / "menu"
        for suffix in (f"{name}Template.png", f"{name}.png"):
            p = base / suffix
            if p.exists():
                return p
        return None
    for suffix in (f"{name}Template.png", f"{name}.png"):
        p = ROOT / "assets" / "icons" / "menu" / suffix
        if p.exists():
            return p
    return None


def get_config_path() -> Path:
    """Return the path to config.json (project root in dev, Application Support when run from .app)."""
    app_bundle = _get_app_bundle()
    if not app_bundle:
        return ROOT / "config.json"

    support_dir = APPLICATION_SUPPORT_DIR
    config_path = support_dir / "config.json"

    if not config_path.exists():
        support_dir.mkdir(parents=True, exist_ok=True)
        # py2app copies data_files to Contents/Resources/ (no app/ subdir)
        default_in_bundle = Path(app_bundle) / "Contents" / "Resources" / "config.json"
        if default_in_bundle.exists():
            try:
                shutil.copy2(default_in_bundle, config_path)
            except OSError as e:
                logging.getLogger(__name__).warning("Could not copy default config from bundle: %s", e)
                _write_minimal_config(config_path)
        else:
            _write_minimal_config(config_path)

    return config_path


def _write_minimal_config(path: Path) -> None:
    """Writes a minimal config.json so the app can start."""
    try:
        with open(path, "w") as f:
            json.dump({"autostart": False}, f, indent=4)
    except OSError as e:
        logging.getLogger(__name__).error("Could not write minimal config to %s: %s", path, e)


def get_log_file_path() -> Path:
    """Returns the path to the app log file (macOS Library/Logs)."""
    return Path(os.path.expanduser("~/Library/Logs/Click-n-speak.log"))


def get_phrases_file_path() -> Path:
    """Returns the path to the phrase history file (project root in dev, Application Support when run from .app)."""
    if not _get_app_bundle():
        return ROOT / "phrase_history.txt"
    support_dir = APPLICATION_SUPPORT_DIR
    support_dir.mkdir(parents=True, exist_ok=True)
    return support_dir / "phrase_history.txt"


# UI strings for notifications and menu bar, keyed by primary language (ru, en, de, es, fr).
# Fallback: en if key or lang missing.
UI_STRINGS: dict[str, dict[str, str]] = {
    "ru": {
        "transcription_instruction": "Расставляй знаки препинания. Пиши с заглавной буквы. ",
        "preparing_title": "Подготовка модели...",
        "preparing_body": "Загружаю/скачиваю Whisper-модель. Первый запуск может занять время.",
        "model_ready_title": "Модель готова",
        "model_ready_body": "Можно начинать диктовку.",
        "warmup_failed_title": "Подготовка модели не удалась",
        "warmup_failed_body": "Запись продолжит работать, но первый распознающий запрос может быть медленнее.",
        "preparing_wait_title": "Подготовка модели...",
        "preparing_wait_body": "Подождите несколько секунд и попробуйте снова.",
        "recording_title": "Запись...",
        "recording_body": "Говорите. Нажмите горячую клавишу ещё раз, чтобы остановить.",
        "transcribing_title": "Распознаю...",
        "transcribing_body": "Идёт распознавание речи. Подождите.",
        "still_working_title": "Распознаю... всё ещё идёт",
        "still_working_body": "Распознавание ещё выполняется. Подождите.",
        "ready_title": "Готово",
        "ready_body": "Распознавание завершено. Можно диктовать снова.",
        "started_title": "Запущено",
        "started_body": "Нажмите горячую клавишу, чтобы начать запись, или используйте иконку в меню-баре.",
        "menu_recording": "● ЗАПИСЬ",
        "menu_processing": "● РАСПОЗН.",
        "edit_confirm_title": "Редактируй и нажми Enter",
    },
    "en": {
        "transcription_instruction": "Add punctuation. Capitalize sentences. ",
        "preparing_title": "Preparing model...",
        "preparing_body": "Loading/downloading Whisper model. First run may take a while.",
        "model_ready_title": "Model ready",
        "model_ready_body": "You can start dictation now.",
        "warmup_failed_title": "Warm-up failed",
        "warmup_failed_body": "Recording will still work, but first transcription may be slower.",
        "preparing_wait_title": "Preparing model...",
        "preparing_wait_body": "Please wait a few seconds and try again.",
        "recording_title": "Recording...",
        "recording_body": "Speak now. Press the hotkey again to stop.",
        "transcribing_title": "Transcribing...",
        "transcribing_body": "Recognition in progress. Please wait.",
        "still_working_title": "Transcribing... still working",
        "still_working_body": "Recognition is still in progress. Please wait.",
        "ready_title": "Ready",
        "ready_body": "Transcription complete. You can dictate again.",
        "started_title": "Started",
        "started_body": "Press the hotkey to start recording or use the menu bar icon.",
        "menu_recording": "● RECORDING",
        "menu_processing": "● RECOGNIZING",
        "edit_confirm_title": "Edit and press Enter",
    },
    "de": {
        "transcription_instruction": "Satzzeichen setzen. Sätze groß schreiben. ",
        "preparing_title": "Modell wird vorbereitet...",
        "preparing_body": "Whisper-Modell wird geladen/heruntergeladen. Der erste Start kann dauern.",
        "model_ready_title": "Modell bereit",
        "model_ready_body": "Sie können jetzt diktieren.",
        "warmup_failed_title": "Vorbereitung fehlgeschlagen",
        "warmup_failed_body": "Aufnahme funktioniert weiter, die erste Erkennung kann langsamer sein.",
        "preparing_wait_title": "Modell wird vorbereitet...",
        "preparing_wait_body": "Bitte warten Sie einige Sekunden und versuchen Sie es erneut.",
        "recording_title": "Aufnahme...",
        "recording_body": "Sprechen Sie. Drücken Sie die Hotkey erneut zum Beenden.",
        "transcribing_title": "Erkennung...",
        "transcribing_body": "Spracherkennung läuft. Bitte warten.",
        "still_working_title": "Erkennung... läuft noch",
        "still_working_body": "Die Erkennung läuft noch. Bitte warten.",
        "ready_title": "Fertig",
        "ready_body": "Erkennung abgeschlossen. Sie können erneut diktieren.",
        "started_title": "Gestartet",
        "started_body": "Drücken Sie die Hotkey zum Aufnehmen oder nutzen Sie das Menü-Symbol.",
        "menu_recording": "● AUFNAHME",
        "menu_processing": "● ERKENNUNG",
        "edit_confirm_title": "Bearbeiten und Enter drücken",
    },
    "es": {
        "transcription_instruction": "Añade puntuación. Escribe con mayúsculas. ",
        "preparing_title": "Preparando modelo...",
        "preparing_body": "Cargando/descargando modelo Whisper. La primera vez puede tardar.",
        "model_ready_title": "Modelo listo",
        "model_ready_body": "Puede empezar a dictar.",
        "warmup_failed_title": "Error al preparar",
        "warmup_failed_body": "La grabación seguirá funcionando, pero la primera transcripción puede ser más lenta.",
        "preparing_wait_title": "Preparando modelo...",
        "preparing_wait_body": "Espere unos segundos e intente de nuevo.",
        "recording_title": "Grabando...",
        "recording_body": "Hable. Pulse la tecla de nuevo para terminar.",
        "transcribing_title": "Transcribiendo...",
        "transcribing_body": "Reconocimiento en curso. Espere.",
        "still_working_title": "Transcribiendo... aún en curso",
        "still_working_body": "El reconocimiento sigue en curso. Espere.",
        "ready_title": "Listo",
        "ready_body": "Transcripción completada. Puede dictar de nuevo.",
        "started_title": "Iniciado",
        "started_body": "Pulse la tecla para grabar o use el icono del menú.",
        "menu_recording": "● GRABANDO",
        "menu_processing": "● RECONOCIENDO",
        "edit_confirm_title": "Editar y pulsar Enter",
    },
    "fr": {
        "transcription_instruction": "Ajoutez la ponctuation. Mettez une majuscule en début de phrase. ",
        "preparing_title": "Préparation du modèle...",
        "preparing_body": "Chargement/téléchargement du modèle Whisper. Le premier lancement peut prendre du temps.",
        "model_ready_title": "Modèle prêt",
        "model_ready_body": "Vous pouvez commencer à dicter.",
        "warmup_failed_title": "Échec de la préparation",
        "warmup_failed_body": "L'enregistrement fonctionnera encore, mais la première transcription peut être plus lente.",
        "preparing_wait_title": "Préparation du modèle...",
        "preparing_wait_body": "Veuillez attendre quelques secondes et réessayer.",
        "recording_title": "Enregistrement...",
        "recording_body": "Parlez. Appuyez à nouveau sur le raccourci pour arrêter.",
        "transcribing_title": "Transcription...",
        "transcribing_body": "Reconnaissance en cours. Veuillez patienter.",
        "still_working_title": "Transcription... en cours",
        "still_working_body": "La reconnaissance est toujours en cours. Veuillez patienter.",
        "ready_title": "Terminé",
        "ready_body": "Transcription terminée. Vous pouvez dicter à nouveau.",
        "started_title": "Démarré",
        "started_body": "Appuyez sur le raccourci pour enregistrer ou utilisez l'icône du menu.",
        "menu_recording": "● ENREGISTREMENT",
        "menu_processing": "● RECONNAISSANCE",
        "edit_confirm_title": "Modifier et appuyer sur Entrée",
    },
}


def get_primary_language(config: dict) -> str:
    """Return the primary UI/recognition language from config (e.g. 'ru', 'en'). Default 'ru'."""
    primary = config.get("primary_language")
    if primary and isinstance(primary, str):
        return str(primary).lower().strip()
    lang_list = config.get("languages")
    if isinstance(lang_list, list) and len(lang_list) > 0:
        return str(lang_list[0]).lower().strip()
    return "ru"


def get_allowed_languages(config: dict) -> list[str]:
    """Return the list of languages allowed for recognition: primary + additional (no duplicates)."""
    primary = get_primary_language(config)
    additional = config.get("additional_languages")
    if not isinstance(additional, list):
        additional = []
    # Backward compat: old config had "languages" = [primary, extra, ...]
    if not additional:
        lang_list = config.get("languages")
        if isinstance(lang_list, list) and len(lang_list) > 1:
            additional = [str(x).lower().strip() for x in lang_list[1:] if x]
    seen = {primary}
    result = [primary]
    for lang in additional:
        code = str(lang).lower().strip()
        if code and code not in seen:
            seen.add(code)
            result.append(code)
    return result


def get_ui_strings(primary_lang: str) -> dict[str, str]:
    """Return UI strings for the given primary language. Falls back to 'en' for unknown lang or keys."""
    lang = primary_lang.lower().strip() if primary_lang else "en"
    if lang not in UI_STRINGS:
        lang = "en"
    base = UI_STRINGS.get("en", {})
    overlay = UI_STRINGS.get(lang, {})
    return {**base, **overlay}


def escape_applescript_string(s: str) -> str:
    """Escapes a string for safe use inside AppleScript double-quoted literals."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def setup_logging() -> None:
    """Configures logging to file and console.

    Uses WatchedFileHandler so that if the log file is deleted while the app is
    running, it is automatically recreated on the next log write.
    """
    from logging.handlers import WatchedFileHandler

    log_file = get_log_file_path()
    fmt = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
    root = logging.getLogger()
    root.setLevel(logging.INFO)

    try:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_file.touch(exist_ok=True)  # create if missing; no-op if already exists
        fh = WatchedFileHandler(str(log_file), encoding="utf-8")
        fh.setFormatter(fmt)
        root.addHandler(fh)
    except OSError as e:
        root.warning("Could not set up file logging to %s: %s — logging to console only.", log_file, e)

    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    console.setFormatter(fmt)
    root.addHandler(console)


setup_logging()
logger = logging.getLogger(__name__)


def log_info(message: str) -> None:
    logger.info(message)


def log_error(message: str) -> None:
    logger.error(message)


def log_exception(message: str) -> None:
    """Log an error message with full traceback."""
    logger.exception(message)


def save_config_to_disk(config: dict) -> None:
    """Atomically write config dict to config.json.

    Writes to a sibling temp file then calls os.replace() so a crash or SIGKILL
    mid-write never leaves a partial/empty JSON file that would wipe user_terms on
    the next launch.
    """
    import json
    import tempfile

    config_path = get_config_path()
    tmp_path = None
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=config_path.parent, suffix=".tmp")
        tmp_path = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(config, f, indent=4)
                f.flush()
                os.fsync(f.fileno())
        except Exception:
            os.close(fd)
            raise
        os.replace(tmp_path, config_path)
    except OSError as e:
        log_error(f"Error saving config: {e}")
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass


# Language hints passed to Whisper as initial_prompt prefix.
# Defined here (not menu_bar.py) so build_initial_prompt can use them without circular imports.
LANG_PROMPTS: dict[str, str] = {
    "ru": "Русский язык.",
    "en": "English language.",
    "de": "Deutscher Text.",
    "es": "Texto en español.",
    "fr": "Texte en français.",
}

# One natural sentence per language used as a style-and-register hint for Whisper
# when the user has not yet added any terms. A natural sentence in-domain is more
# effective than a bare language name because it shows Whisper the expected
# punctuation, register, and vocabulary class.
LANG_DEFAULT_CONTEXT: dict[str, str] = {
    "ru": "Это разговорная речь. Используются профессиональные термины и аббревиатуры.",
    "en": "This is spoken language with professional and technical vocabulary.",
    "de": "Dies ist gesprochene Sprache mit Fachbegriffen.",
    "es": "Este es lenguaje hablado con vocabulario técnico y profesional.",
    "fr": "Ceci est du langage parlé avec du vocabulaire professionnel et technique.",
}

# Normalised set for filtering language-hint phrases during term parsing.
_LANG_HINT_LOWER: set[str] = {v.lower().rstrip(". ") for v in LANG_PROMPTS.values()}

# Whisper's hard prompt limit is 224 BPE tokens. We budget 200 tokens for the
# vocab/hint portion (app.py reserves the rest for the per-chunk instruction).
# Cyrillic characters encode as 2-3 tokens each, so a char-based cap of 500
# can silently overflow the budget with Russian text. We therefore estimate
# tokens via the Whisper tokenizer when available, and fall back to a very
# conservative 3 chars/token heuristic (240 chars ≈ 80 tokens — safe worst case).
_MAX_PROMPT_TOKENS = 200
_MAX_PROMPT_CHARS_FALLBACK = 400  # used only when tokenizer is unavailable

# Lazy-loaded Whisper BPE encoder for token-accurate prompt truncation.
_prompt_tokenizer = None
_prompt_tokenizer_tried: bool = False


def _count_prompt_tokens(text: str) -> int:
    """Estimate BPE token count for *text* using the Whisper multilingual tokenizer.

    Falls back to len(text) // 3 (conservative for Cyrillic) if unavailable.
    """
    global _prompt_tokenizer, _prompt_tokenizer_tried
    if not _prompt_tokenizer_tried:
        _prompt_tokenizer_tried = True
        try:
            from mlx_whisper.tokenizer import get_tokenizer  # type: ignore
            _prompt_tokenizer = get_tokenizer(multilingual=True, language="en").encoding
        except Exception:
            pass
    if _prompt_tokenizer is not None:
        raw = len(_prompt_tokenizer.encode(text))
        if raw > 0:
            return raw
        # raw == 0 means the tokenizer is a mock/stub (tests) — fall through to heuristic
    return max(1, len(text) // 3)


def parse_prompt_terms(text: str) -> list[str]:
    """Split a comma- or newline-separated string into individual terms.

    Strips whitespace and trailing punctuation from each item; skips blank tokens
    and raw language-hint phrases (e.g. 'Русский язык.').
    """
    import re
    result: list[str] = []
    seen_lower: set[str] = set()
    for part in re.split(r"[,\n]+", text):
        t = part.strip(" .")
        if not t:
            continue
        key = t.lower()
        if key in _LANG_HINT_LOWER:
            continue
        if key not in seen_lower:
            seen_lower.add(key)
            result.append(t)
    return result


def deduplicate_prompt_terms(terms: list[str]) -> list[str]:
    """Deduplicate a list of terms case-insensitively, preserving first occurrence."""
    seen_lower: set[str] = set()
    result: list[str] = []
    for term in terms:
        key = term.lower().strip()
        if key and key not in seen_lower:
            seen_lower.add(key)
            result.append(term)
    return result


def build_initial_prompt(config: dict) -> str:
    """Build the effective Whisper initial_prompt from user_terms for all active languages.

    Token-accurate truncation: adds terms one-by-one until the BPE token budget
    (_MAX_PROMPT_TOKENS) is reached, so Cyrillic-heavy prompts don't silently
    overflow Whisper's 224-token limit.
    """
    primary = get_primary_language(config)
    additional = list(config.get("additional_languages") or [])

    # Language hints for every active language.
    all_langs = [primary] + [l for l in additional if l != primary]
    lang_hint = " ".join(LANG_PROMPTS[l] for l in all_langs if l in LANG_PROMPTS)

    user_terms: dict = config.get("user_terms") or {}

    terms: list[str] = list(user_terms.get(primary, []))
    for lang in additional:
        if lang != primary:
            terms.extend(user_terms.get(lang, []))
    terms = deduplicate_prompt_terms(terms)

    primary_has_terms = bool(user_terms.get(primary))

    # Build the fixed prefix (lang hint + optional style sentence)
    if not terms:
        if primary in LANG_DEFAULT_CONTEXT:
            result = f"{lang_hint} {LANG_DEFAULT_CONTEXT[primary]}".strip()
        else:
            result = lang_hint
        return result.strip()

    if not primary_has_terms and primary in LANG_DEFAULT_CONTEXT:
        prefix = f"{lang_hint} {LANG_DEFAULT_CONTEXT[primary]} "
    else:
        prefix = f"{lang_hint} "

    # Add terms one-by-one until the token budget is exhausted.
    prefix_tokens = _count_prompt_tokens(prefix)
    budget = _MAX_PROMPT_TOKENS - prefix_tokens
    accepted: list[str] = []
    used_tokens = 0
    for term in terms:
        if not str(term).strip():
            continue
        fragment = (", " if accepted else "") + term
        cost = _count_prompt_tokens(fragment)
        if used_tokens + cost > budget:
            break
        accepted.append(term)
        used_tokens += cost

    if accepted:
        result = (prefix + ", ".join(accepted)).strip()
    elif primary in LANG_DEFAULT_CONTEXT:
        result = f"{lang_hint} {LANG_DEFAULT_CONTEXT[primary]}".strip()
    else:
        result = lang_hint

    return result.strip()


def migrate_config_to_v2(config: dict) -> dict:
    """One-time migration from v1 schema to v2 (user_terms / auto_terms).

    Idempotent: returns unchanged dict when schema_version >= 2.
    Parses comma-separated terms from custom_prompts[lang] or the legacy
    initial_prompt field and stores them in user_terms[lang], removing all
    legacy keys (custom_prompts, previous_prompts, previous_initial_prompt,
    language_hint, terms_hint).
    """
    if config.get("schema_version", 1) >= 2:
        return config

    primary = get_primary_language(config)
    custom_prompts: dict = config.get("custom_prompts") or {}
    candidate_langs: set[str] = set(custom_prompts.keys())
    if config.get("initial_prompt"):
        candidate_langs.add(primary)

    user_terms: dict[str, list[str]] = {}
    for lang in candidate_langs:
        source = custom_prompts.get(lang) or (config.get("initial_prompt", "") if lang == primary else "")
        if source:
            terms = deduplicate_prompt_terms(parse_prompt_terms(source))
            if terms:
                user_terms[lang] = terms

    config["schema_version"] = 2
    config["user_terms"] = user_terms
    config.setdefault("auto_terms", {})
    config.setdefault("prompt_snapshots", {})
    config.setdefault("pending_suggestions", {})
    config.setdefault("skipped_terms", {})
    config.setdefault("prompt_update_mode", "suggest")
    config.setdefault("auto_prompt_check_interval", 50)
    config.setdefault("last_analysis_phrase_count", 0)

    # Remove all v1 keys.
    for key in ("custom_prompts", "previous_prompts", "previous_initial_prompt",
                "language_hint", "terms_hint"):
        config.pop(key, None)

    # Refresh the cached initial_prompt field.
    config["initial_prompt"] = build_initial_prompt(config)

    return config


def migrate_config_to_v3(config: dict) -> dict:
    """Merge auto_terms into user_terms and remove the auto_terms bucket.

    Idempotent: returns unchanged dict when schema_version >= 3.
    Auto-detected terms are appended after existing user_terms so the
    user-curated order is preserved.
    """
    if config.get("schema_version", 1) >= 3:
        return config

    auto_terms: dict = config.get("auto_terms") or {}
    if auto_terms:
        user_terms = dict(config.get("user_terms") or {})
        for lang, terms in auto_terms.items():
            if terms:
                current = list(user_terms.get(lang, []))
                user_terms[lang] = deduplicate_prompt_terms(current + list(terms))
        config["user_terms"] = user_terms

    config["schema_version"] = 3
    config.pop("auto_terms", None)
    config["initial_prompt"] = build_initial_prompt(config)
    return config


def migrate_config_to_v4(config: dict) -> dict:
    """Strip language-hint prefixes embedded in user_terms by the v2 migration.

    Idempotent: returns unchanged dict when schema_version >= 4.
    The v2 migration parsed the raw initial_prompt by splitting on commas, but
    the language hint ('Русский язык.', 'English language.', etc.) was glued to
    the first term (no comma separator), producing entries like
    'Русский язык. Чаще всего я пишу...' or 'English language. readmission'.
    """
    if config.get("schema_version", 1) >= 4:
        return config

    # Build prefix strings: "Русский язык. ", "English language. ", etc.
    hint_prefixes = [h.rstrip(". ") + ". " for h in LANG_PROMPTS.values()]

    user_terms: dict = config.get("user_terms") or {}
    cleaned: dict[str, list[str]] = {}
    for lang, terms in user_terms.items():
        clean: list[str] = []
        for term in terms:
            t = term
            for prefix in hint_prefixes:
                if t.startswith(prefix):
                    t = t[len(prefix):].lstrip()
                    break
            t = t.strip()
            if t:
                clean.append(t)
        cleaned[lang] = deduplicate_prompt_terms(clean)

    config["user_terms"] = cleaned
    config["schema_version"] = 4
    config["initial_prompt"] = build_initial_prompt(config)
    return config


def _run_notification(script: str) -> None:
    try:
        subprocess.run(["osascript", "-e", script], check=True)
    except subprocess.CalledProcessError as e:
        log_error(f"Failed to send notification: {e}")


def send_notification(title, subtitle, info_text):
    """Sends a native macOS notification using AppleScript (non-blocking)."""
    content = f"{subtitle} - {info_text}" if subtitle else info_text
    escaped_title = title.replace('"', '\\"')
    escaped_content = content.replace('"', '\\"')

    script = f'display notification "{escaped_content}" with title "{escaped_title}"'
    # Run in a separate thread to avoid blocking the hotkey listener
    threading.Thread(target=_run_notification, args=(script,), daemon=True).start()


def copy_to_clipboard(text):
    """Copies text to the macOS clipboard."""
    try:
        process = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE, close_fds=True)
        process.communicate(input=text.encode("utf-8"))
        log_info("Text copied to clipboard.")
    except Exception as e:
        log_error(f"Failed to copy to clipboard: {e}")


def play_sound(sound_name: Optional[str] = None) -> None:
    """Plays a system sound (non-blocking). Uses SOUND_RECORDING_START if no path given."""
    path = sound_name if sound_name is not None else SOUND_RECORDING_START
    try:
        subprocess.Popen(
            ["afplay", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as e:
        log_error(f"Failed to play sound {path}: {e}")


def is_accessibility_trusted() -> bool:
    """Return True if the app is a trusted accessibility client."""
    from .permissions import check_accessibility
    return check_accessibility()


def open_accessibility_settings() -> None:
    """Open macOS System Settings on the Accessibility privacy pane."""
    try:
        subprocess.run(
            [
                "open",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            ],
            check=False,
        )
    except Exception as e:
        log_error(f"Failed to open Accessibility settings: {e}")


def open_microphone_settings() -> None:
    """Open macOS System Settings on the Microphone privacy pane."""
    try:
        subprocess.run(
            [
                "open",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            ],
            check=False,
        )
    except Exception as e:
        log_error(f"Failed to open Microphone settings: {e}")


def ensure_accessibility_permission() -> bool:
    """Ensure the app is a trusted accessibility client; prompt and open settings if needed.

    Uses a two-step approach:
    1. Check AXIsProcessTrusted() first (no UI shown).
    2. Only if NOT trusted, call AXIsProcessTrustedWithOptions with prompt=True
       to show the system dialog *once*.
    """
    # Step 1: silent check
    if is_accessibility_trusted():
        log_info("Accessibility already granted — skipping prompt.")
        return True

    # Step 2: not trusted — show prompt once
    log_info("Accessibility not granted. Showing system prompt.")
    try:
        from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
        from Foundation import NSDictionary

        options = NSDictionary.dictionaryWithDictionary_({kAXTrustedCheckOptionPrompt: True})
        trusted = bool(AXIsProcessTrustedWithOptions(options))
    except ImportError:
        log_info("AXIsProcessTrustedWithOptions not available; opening settings manually.")
        trusted = False
    except Exception as exc:
        log_error(f"Accessibility permission check failed: {exc}")
        trusted = False

    if not trusted:
        open_accessibility_settings()
        send_notification(
            "Click-n-speak",
            "Accessibility required",
            "Please allow Click-n-speak under Privacy & Security → Accessibility.",
        )

    return trusted


def wait_for_accessibility(timeout: float = 30.0, poll_interval: float = 1.0) -> bool:
    """Poll AXIsProcessTrusted() until it returns True or timeout expires."""
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if is_accessibility_trusted():
            log_info("Accessibility permission granted (detected by polling).")
            return True
        time.sleep(poll_interval)
    log_info(f"Accessibility not granted after {timeout}s polling.")
    return False
