import json
import logging
import os
import shutil
import subprocess
import threading
from pathlib import Path

# Project root (parent of src/)
ROOT = Path(__file__).resolve().parent.parent

# Application Support dir when running from .app (set by launcher)
APPLICATION_SUPPORT_DIR = Path(os.path.expanduser("~/Library/Application Support/Click-n-speak"))

# macOS system sounds used for recording feedback (configurable via play_sound argument)
SOUND_RECORDING_START = "/System/Library/Sounds/Tink.aiff"
SOUND_RECORDING_STOP = "/System/Library/Sounds/Pop.aiff"


def get_menu_icon_path() -> Path:
    """Return the path to the PNG icon used in the menu bar."""
    app_bundle = os.environ.get("CLICK_N_SPEAK_APP")
    if app_bundle:
        bundle_icon = Path(app_bundle) / "Contents" / "Resources" / "CnS.png"
        if bundle_icon.exists():
            return bundle_icon

    # Fallback: project root when running from source
    return ROOT / "CnS.png"


def get_config_path() -> Path:
    """Return the path to config.json (project root in dev, Application Support when run from .app)."""
    app_bundle = os.environ.get("CLICK_N_SPEAK_APP")
    if not app_bundle:
        return ROOT / "config.json"

    support_dir = APPLICATION_SUPPORT_DIR
    config_path = support_dir / "config.json"

    if not config_path.exists():
        support_dir.mkdir(parents=True, exist_ok=True)
        default_in_bundle = Path(app_bundle) / "Contents" / "Resources" / "app" / "config.json"
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
    app_bundle = os.environ.get("CLICK_N_SPEAK_APP")
    if not app_bundle:
        return ROOT / "phrase_history.txt"
    support_dir = APPLICATION_SUPPORT_DIR
    support_dir.mkdir(parents=True, exist_ok=True)
    return support_dir / "phrase_history.txt"


# UI strings for notifications and menu bar, keyed by primary language (ru, en, de, es, fr).
# Fallback: en if key or lang missing.
UI_STRINGS: dict[str, dict[str, str]] = {
    "ru": {
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
    },
    "en": {
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
    },
    "de": {
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
    },
    "es": {
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
    },
    "fr": {
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
    """Configures logging to file and console."""
    log_file = get_log_file_path()
    try:
        logging.basicConfig(
            filename=log_file,
            level=logging.INFO,
            format="%(asctime)s - %(levelname)s - %(message)s",
        )
    except OSError:
        logging.basicConfig(level=logging.INFO)
        logging.getLogger(__name__).warning("Could not write log file %s, logging to console only.", log_file)

    # Also log to console
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    logging.getLogger("").addHandler(console)


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
    """Writes config dict to config.json in project root. Logs errors."""
    import json

    try:
        with open(get_config_path(), "w") as f:
            json.dump(config, f, indent=4)
    except OSError as e:
        log_error(f"Error saving config: {e}")


def build_initial_prompt(config: dict) -> str:
    """Builds the effective initial_prompt string from config."""
    language_hint = str(config.get("language_hint", "")).strip()
    terms_hint = str(config.get("terms_hint", "")).strip()
    if language_hint and terms_hint:
        return f"{language_hint} {terms_hint}".strip()
    if language_hint:
        return language_hint
    if terms_hint:
        return terms_hint
    return str(config.get("initial_prompt", "")).strip()


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


from typing import Optional

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
    try:
        from ApplicationServices import AXIsProcessTrusted

        return AXIsProcessTrusted()
    except ImportError:
        log_error("ApplicationServices not found, assuming trusted (fallback).")
        return True
    except Exception as e:
        log_error(f"Error checking accessibility permissions: {e}")
        return True


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
    """Poll AXIsProcessTrusted() until it returns True or timeout expires.

    Returns True if accessibility was granted within the timeout.
    """
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if is_accessibility_trusted():
            log_info("Accessibility permission granted (detected by polling).")
            return True
        time.sleep(poll_interval)
    log_info(f"Accessibility not granted after {timeout}s polling.")
    return False
