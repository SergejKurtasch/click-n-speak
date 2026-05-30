import json
import logging
import os
import re
import shutil
import string
import subprocess
import sys
import threading
from datetime import datetime, timedelta, timezone
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
        config_path = ROOT / "config.json"
        if not config_path.exists():
            example = ROOT / "config.example.json"
            if example.exists():
                try:
                    shutil.copy2(example, config_path)
                except OSError as e:
                    logging.getLogger(__name__).warning("Could not copy config.example.json: %s", e)
        return config_path

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


def get_corrections_file_path() -> Path:
    """Return the path to corrections.json (dev root or Application Support)."""
    if not _get_app_bundle():
        return ROOT / "corrections.json"
    support_dir = APPLICATION_SUPPORT_DIR
    support_dir.mkdir(parents=True, exist_ok=True)
    return support_dir / "corrections.json"


def get_metrics_history_path() -> Path:
    """Return path to metrics_history.jsonl (dev root or Application Support)."""
    if not _get_app_bundle():
        return ROOT / "metrics_history.jsonl"
    support_dir = APPLICATION_SUPPORT_DIR
    support_dir.mkdir(parents=True, exist_ok=True)
    return support_dir / "metrics_history.jsonl"


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
        "popup_title_with_hotkey": "Редактируй · Enter подтвердить · ⌘D добавить термин",
        "toast_added": "Добавлено: {term}",
        "toast_invalid_term": "Невалидный термин",
        "toast_exists": "Уже в словаре",
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
        "popup_title_with_hotkey": "Edit · Enter to confirm · ⌘D to add term",
        "toast_added": "Added: {term}",
        "toast_invalid_term": "Not a valid term",
        "toast_exists": "Already in dictionary",
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
        return normalize_lang_code(primary)
    lang_list = config.get("languages")
    if isinstance(lang_list, list) and len(lang_list) > 0:
        return normalize_lang_code(lang_list[0])
    return "ru"


def normalize_lang_code(lang_code: str) -> str:
    """Canonicalise language code for internal use.

    The app historically used "ua" for Ukrainian in UI/config. Internally we
    now use ISO 639-1 "uk" everywhere while keeping UI labels as "UA".
    """
    code = str(lang_code or "").lower().strip()
    return "uk" if code == "ua" else code


def _dedupe_lang_list(languages: list[str], *, primary: str | None = None) -> list[str]:
    """Return language codes with stable order and no duplicates."""
    out: list[str] = []
    seen: set[str] = set()
    primary_code = normalize_lang_code(primary) if primary else None
    for lang in languages:
        code = normalize_lang_code(lang)
        if not code:
            continue
        if primary_code and code == primary_code:
            continue
        if code in seen:
            continue
        seen.add(code)
        out.append(code)
    return out


LANG_NAMES: dict[str, str] = {
    "ru": "Русский",
    "en": "English",
    "uk": "Українська",
    "de": "Deutsch",
    "fr": "Français",
    "es": "Español",
    "it": "Italiano",
    "pl": "Polski",
    "pt": "Português",
    "zh": "中文",
    "ja": "日本語",
    "ko": "한국어",
}


def detect_term_script(term: str) -> str | None:
    """Return dominant script of a term: 'latin', 'cyrillic', or None.

    None means no alphabetic chars, or Latin and Cyrillic counts are equal.
    Used for script-aware dictionary routing (⌘D, auto-add).
    """
    latin = sum(1 for c in term if c.isalpha() and ord(c) < 0x400)
    cyrillic = sum(1 for c in term if c.isalpha() and 0x0400 <= ord(c) <= 0x052F)
    if latin == 0 and cyrillic == 0:
        return None
    if latin > cyrillic:
        return "latin"
    if cyrillic > latin:
        return "cyrillic"
    return None  # tied — caller should fall back to primary lang


def get_language_script(lang_code: str) -> str:
    """Return script family for a configured language: 'latin' or 'cyrillic'.

    Used to align ISO language codes with analyzer script buckets (latin/cyrillic).
    Cyrillic: ru, uk/ua, be, bg, mk, sr. Everything else is treated as latin.
    """
    cyrillic_langs = {"ru", "uk", "ua", "be", "bg", "mk", "sr"}
    return "cyrillic" if normalize_lang_code(lang_code) in cyrillic_langs else "latin"


def target_lang_for_script_bucket(
    script: str,
    primary_lang: str,
    additional_langs: list[str] | None,
) -> str:
    """Map analyzer script bucket ('latin' | 'cyrillic') to one configured language code.

    Prefers primary when its script matches, otherwise the first additional language
    whose script matches. Falls back to primary (same role as legacy en/ru remap).
    """
    primary = str(primary_lang).lower().strip()
    additional = [str(x).lower().strip() for x in (additional_langs or []) if x]
    if get_language_script(primary) == script:
        return primary
    for code in additional:
        if get_language_script(code) == script:
            return code
    return primary


def existing_terms_union_for_script(
    existing_lower_by_lang: dict[str, set[str]],
    script: str,
) -> set[str]:
    """Union of lowercase terms across all configured languages that use *script*."""
    out: set[str] = set()
    for lang_code, terms in (existing_lower_by_lang or {}).items():
        if get_language_script(lang_code) == script:
            out |= {canonical_term_key(t) for t in terms if canonical_term_key(t)}
    return out


def skipped_phrases_merge_for_script(
    skipped_lower_by_lang: dict[str, dict[str, int]],
    script: str,
) -> dict[str, int]:
    """Merge skipped-term phrase indices across langs matching *script* (max per term)."""
    merged: dict[str, int] = {}
    for lang_code, sk in (skipped_lower_by_lang or {}).items():
        if get_language_script(lang_code) != script:
            continue
        for lower, cnt in sk.items():
            key = canonical_term_key(lower)
            if not key:
                continue
            merged[key] = max(merged.get(key, -1), int(cnt))
    return merged


# Maps config language codes to Whisper ISO-639-1 codes.
# Keep the legacy ua->uk alias for backward compatibility with old configs.
_WHISPER_LANG_CODE: dict[str, str] = {"ua": "uk"}


def get_allowed_languages(config: dict) -> list[str]:
    """Return the list of languages allowed for recognition: primary + additional (no duplicates)."""
    primary = normalize_lang_code(get_primary_language(config))
    additional = config.get("additional_languages")
    if not isinstance(additional, list):
        additional = []
    # Backward compat: old config had "languages" = [primary, extra, ...]
    if not additional:
        lang_list = config.get("languages")
        if isinstance(lang_list, list) and len(lang_list) > 1:
            additional = [normalize_lang_code(x) for x in lang_list[1:] if x]
    additional = _dedupe_lang_list(additional, primary=primary)
    seen = {primary}
    result = [_WHISPER_LANG_CODE.get(primary, primary)]
    for code in additional:
        if code and code not in seen:
            seen.add(code)
            result.append(_WHISPER_LANG_CODE.get(code, code))
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


def log_warning(message: str) -> None:
    logger.warning(message)


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
    config_path = get_config_path()
    try:
        write_json_atomic(config_path, config, indent=4)
    except OSError as e:
        log_error(f"Error saving config: {e}")


def write_json_atomic(path: Path, payload: object, *, indent: int | None = None) -> None:
    """Atomically write JSON payload to *path* using temp file + os.replace."""
    import tempfile

    tmp_path = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        tmp_path = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=indent)
                f.flush()
                os.fsync(f.fileno())
        except Exception:
            raise
        os.replace(tmp_path, path)
    except OSError:
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass
        raise


def write_text_atomic(path: Path, text: str) -> None:
    """Atomically write *text* to *path* using temp file + os.replace + fsync."""
    import tempfile

    tmp_path = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        tmp_path = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
                f.flush()
                os.fsync(f.fileno())
        except Exception:
            raise
        os.replace(tmp_path, path)
    except OSError:
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass
        raise


# Language hints passed to Whisper as initial_prompt prefix.
# Defined here (not menu_bar.py) so build_initial_prompt can use them without circular imports.
LANG_PROMPTS: dict[str, str] = {
    "ru": "Русский язык.",
    "en": "English language.",
    "de": "Deutscher Text.",
    "es": "Texto en español.",
    "fr": "Texte en français.",
    "it": "Testo in italiano.",
    "pt": "Texto em português.",
    "nl": "Nederlandse tekst.",
    "pl": "Tekst po polsku.",
    "uk": "Українська мова.",
    "tr": "Türkçe metin.",
    "zh": "中文文本。",
    "ja": "日本語テキスト。",
    "ko": "한국어 텍스트。",
    "ar": "نص عربي.",
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
    "it": "Questo è linguaggio parlato con vocabolario professionale e tecnico.",
    "pt": "Esta é linguagem falada com vocabulário profissional e técnico.",
    "nl": "Dit is gesproken taal met professionele en technische woordenschat.",
    "pl": "To jest mowa potoczna z profesjonalnym słownictwem technicznym.",
    "uk": "Це розмовна мова з використанням професійних термінів і абревіатур.",
    "tr": "Bu, profesyonel ve teknik kelime hazinesiyle konuşma dilidir.",
    "zh": "这是口语，使用专业和技术词汇。",
    "ja": "これは専門的・技術的な語彙を使った話し言葉です。",
    "ko": "이것은 전문적이고 기술적인 어휘가 포함된 구어체입니다。",
    "ar": "هذا هو اللغة المنطوقة مع المفردات المهنية والتقنية.",
}

# Boundary punctuation removed from terms (leading/trailing only).
# Keep +/#/_/- because they can be meaningful in technical terms (C++, C#, x-y).
_TERM_BOUNDARY_PUNCT: set[str] = (
    (set(string.punctuation) - set("+#_-"))
    | set("«»“”„‟‘’‚‛…—–·，。！？、：；（）【】《》「」『』")
)
_SEMANTIC_LEADING_PUNCT: set[str] = {".", "@"}


def _is_semantic_leading_punct(text: str, idx: int) -> bool:
    """True when boundary punctuation is part of a meaningful term prefix."""
    if idx < 0 or idx >= len(text):
        return False
    ch = text[idx]
    if ch not in _SEMANTIC_LEADING_PUNCT:
        return False
    if idx + 1 >= len(text):
        return False
    return text[idx + 1].isalnum()


def canonicalize_term(term: str) -> str:
    """Normalize a term for display/storage without touching inner symbols.

    - trims surrounding whitespace
    - removes only leading/trailing punctuation
    - keeps inner punctuation/symbols (e.g. C++, node.js, v2.1)
    """
    text = " ".join(str(term or "").split())
    if not text:
        return ""
    start = 0
    end = len(text)
    while start < end and text[start] in _TERM_BOUNDARY_PUNCT:
        # Preserve semantic prefixes like ".NET" and "@mention".
        if _is_semantic_leading_punct(text, start):
            break
        start += 1
    while end > start and text[end - 1] in _TERM_BOUNDARY_PUNCT:
        end -= 1
    return text[start:end]


def canonical_term_key(term: str) -> str:
    """Return lowercase identity key for a term after boundary normalization."""
    return canonicalize_term(term).lower()


# Normalised set for filtering language-hint phrases during term parsing.
_LANG_HINT_LOWER: set[str] = {canonical_term_key(v.rstrip(". ")) for v in LANG_PROMPTS.values()}

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
        t = canonicalize_term(part)
        if not t:
            continue
        key = canonical_term_key(t)
        if key in _LANG_HINT_LOWER:
            continue
        if key not in seen_lower:
            seen_lower.add(key)
            result.append(t)
    return result


def _term_str(item) -> str:
    """Return the term string from a str or v5 dict entry."""
    return item if isinstance(item, str) else item["term"]


def _term_is_active(item) -> bool:
    """Return False only for v5 dict entries explicitly marked inactive."""
    return not (isinstance(item, dict) and item.get("inactive"))


def _term_sort_key(item) -> tuple:
    """Sort key: manual(0) < correction(1) < auto(2); then use_count desc; then last_seen desc."""
    if isinstance(item, str):
        return (0, 0, "")
    src_order = {"manual": 0, "correction": 1, "auto": 2}.get(item.get("source", "manual"), 3)
    use_count = -(item.get("use_count") or 0)
    last_seen = item.get("last_seen") or ""
    return (src_order, use_count, last_seen)


def deduplicate_prompt_terms(terms: list) -> list:
    """Deduplicate terms case-insensitively, preserving first occurrence.

    Accepts lists of str or v5 dict entries (or mixed); returns items of the same types.
    """
    seen_lower: set[str] = set()
    result = []
    for item in terms:
        key = canonical_term_key(_term_str(item))
        if key and key not in seen_lower:
            seen_lower.add(key)
            result.append(item)
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

    # Collect active terms only; sort by priority (manual > correction > auto by use_count).
    raw: list = [t for t in user_terms.get(primary, []) if _term_is_active(t)]
    for lang in additional:
        if lang != primary:
            raw.extend(t for t in user_terms.get(lang, []) if _term_is_active(t))
    raw = sorted(raw, key=_term_sort_key)
    terms: list[str] = [_term_str(t) for t in deduplicate_prompt_terms(raw)]

    primary_has_terms = any(_term_is_active(t) for t in user_terms.get(primary, []))

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
    config.setdefault("auto_prompt_check_interval", 20)
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


def migrate_config_to_v5(config: dict) -> dict:
    """Add per-term metadata (source, added_at, last_seen, use_count) to user_terms.

    Idempotent: returns unchanged dict when schema_version >= 5.
    Legacy string entries are converted to dicts with source="manual" so they
    are never touched by the decay algorithm.
    """
    if config.get("schema_version", 1) >= 5:
        return config

    now_iso = datetime.now(timezone.utc).isoformat()
    new_user_terms: dict[str, list[dict]] = {}
    for lang, terms in (config.get("user_terms") or {}).items():
        new_list = []
        for t in terms:
            if isinstance(t, str):
                new_list.append({
                    "term": t,
                    "source": "manual",
                    "added_at": now_iso,
                    "last_seen": now_iso,
                    "use_count": 0,
                })
            elif isinstance(t, dict):
                new_list.append(t)
        new_user_terms[lang] = new_list

    config["user_terms"] = new_user_terms
    config["schema_version"] = 5
    config.setdefault("last_decay_run_ts", None)
    config.setdefault("max_dictionary_age_days", 60)
    config["initial_prompt"] = build_initial_prompt(config)
    return config


def migrate_config_to_v6(config: dict) -> dict:
    """Add manual replacement pairs for misrecognition hints and direct fallback replace.

    Idempotent when schema_version >= 6.
    """
    if config.get("schema_version", 1) >= 6:
        config.setdefault("manual_replacements", [])
        return config

    raw = config.get("manual_replacements")
    cleaned: list[dict] = []
    if isinstance(raw, list):
        for item in raw:
            if not isinstance(item, dict):
                continue
            fr = str(item.get("from", "")).strip()
            to = str(item.get("to", "")).strip()
            if not fr or not to:
                continue
            entry = {"from": fr, "to": to}
            added_at = item.get("added_at")
            if isinstance(added_at, str) and added_at.strip():
                entry["added_at"] = added_at.strip()
            cleaned.append(entry)

    config["manual_replacements"] = cleaned
    config["schema_version"] = 6
    return config


def normalize_ukrainian_lang_codes(config: dict) -> dict:
    """Normalize legacy 'ua' codes to canonical internal 'uk'.

    Applies to top-level language fields and language-keyed maps while preserving
    data. Dictionary-like sections are merged deterministically when both `ua`
    and `uk` entries exist.
    """
    primary = config.get("primary_language")
    if isinstance(primary, str):
        config["primary_language"] = normalize_lang_code(primary)

    additional = config.get("additional_languages")
    if isinstance(additional, list):
        config["additional_languages"] = _dedupe_lang_list(additional, primary=config.get("primary_language"))

    # Legacy v1 field support.
    legacy_langs = config.get("languages")
    if isinstance(legacy_langs, list):
        config["languages"] = _dedupe_lang_list(legacy_langs)

    def _merge_lang_lists(section: str) -> None:
        raw = config.get(section)
        if not isinstance(raw, dict):
            return
        merged: dict[str, list] = {}
        for lang, values in raw.items():
            if not isinstance(values, list):
                continue
            key = normalize_lang_code(lang)
            current = list(merged.get(key, []))
            merged[key] = deduplicate_prompt_terms(current + list(values))
        config[section] = merged

    _merge_lang_lists("user_terms")
    _merge_lang_lists("pending_suggestions")
    _merge_lang_lists("prompt_snapshots")

    skipped_raw = config.get("skipped_terms")
    if isinstance(skipped_raw, dict):
        merged_skipped: dict[str, dict[str, int]] = {}
        for lang, terms in skipped_raw.items():
            if not isinstance(terms, dict):
                continue
            key = normalize_lang_code(lang)
            bucket = merged_skipped.setdefault(key, {})
            for term, cnt in terms.items():
                canonical = canonical_term_key(term)
                if not canonical:
                    continue
                bucket[canonical] = max(bucket.get(canonical, -1), int(cnt))
        config["skipped_terms"] = merged_skipped

    return config


def update_term_usage(config: dict, phrase: str) -> bool:
    """Bump use_count and last_seen for any v5 dict terms found in *phrase*.

    Single-word terms are matched via token set; multi-word terms via substring.
    Returns True if at least one term was updated (dirty-flag hint for caller).
    """
    phrase_lower = phrase.lower()
    tokens: set[str] = set(re.findall(r"[\w'-]+", phrase_lower))
    now_iso = datetime.now(timezone.utc).isoformat()
    dirty = False
    for lang, terms in (config.get("user_terms") or {}).items():
        for item in terms:
            if not isinstance(item, dict):
                continue
            term_lower = canonical_term_key(item["term"])
            if " " in term_lower:
                found = term_lower in phrase_lower
            else:
                found = term_lower in tokens
            if found:
                item["last_seen"] = now_iso
                item["use_count"] = item.get("use_count", 0) + 1
                if item.get("inactive"):
                    item.pop("inactive")
                dirty = True
    return dirty


_FAST_DECAY_AGE_DAYS = 14
_FAST_DECAY_MIN_USE_COUNT = 1  # use_count < 1 means never used


def apply_fast_decay(config: dict) -> int:
    """Deactivate auto-terms that were never useful (use_count=0, older than 14 days).

    Complements apply_decay: catches zero-use clutter before the 60-day slow decay
    window so it doesn't occupy prompt token budget for weeks.
    Returns number of terms deactivated.
    """
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=_FAST_DECAY_AGE_DAYS)
    deactivated = 0
    for _lang, terms in (config.get("user_terms") or {}).items():
        for item in terms:
            if not isinstance(item, dict):
                continue
            if item.get("source") != "auto":
                continue
            if item.get("inactive"):
                continue
            if item.get("use_count", 0) >= _FAST_DECAY_MIN_USE_COUNT:
                continue
            raw_added = item.get("added_at")
            if not raw_added:
                continue
            try:
                added_at = datetime.fromisoformat(raw_added)
            except ValueError:
                continue
            if added_at.tzinfo is None:
                added_at = added_at.replace(tzinfo=timezone.utc)
            if added_at > cutoff:
                continue
            item["inactive"] = True
            deactivated += 1
    return deactivated


def apply_decay(config: dict, max_age_days: int | None = None) -> int:
    """Mark stale auto/correction terms inactive in initial_prompt.

    Runs two passes:
    1. Fast decay (apply_fast_decay): auto terms with use_count=0 older than 14 days.
    2. Slow decay: any non-manual term with last_seen older than max_age_days AND use_count < 3.

    Returns total number of terms deactivated. Manual terms are never touched.
    """
    n_fast = apply_fast_decay(config)

    if max_age_days is None:
        max_age_days = int(config.get("max_dictionary_age_days", 60))
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=max_age_days)
    n_slow = 0
    for lang, terms in (config.get("user_terms") or {}).items():
        for item in terms:
            if not isinstance(item, dict):
                continue
            if item.get("source") == "manual":
                continue
            raw_ts = item.get("last_seen") or item.get("added_at")
            if not raw_ts:
                continue
            try:
                last_seen = datetime.fromisoformat(raw_ts)
            except ValueError:
                continue
            # Make timezone-aware if naive
            if last_seen.tzinfo is None:
                last_seen = last_seen.replace(tzinfo=timezone.utc)
            if last_seen < cutoff and item.get("use_count", 0) < 3:
                if not item.get("inactive"):
                    item["inactive"] = True
                    n_slow += 1
    return n_fast + n_slow


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
