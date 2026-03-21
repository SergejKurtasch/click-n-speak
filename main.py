import os
import sys
import threading

from src.app import SVoiceRecApp
from src.menu_bar import ClickNSpeakApp
from src.updater import check_for_update
from src.utils import (
    ensure_accessibility_permission,
    get_config_path,
    get_primary_language,
    get_ui_strings,
    log_error,
    log_info,
    send_notification,
)


def _run_update_check_once() -> None:
    """Run update check once in background (non-blocking)."""
    try:
        check_for_update(open_url_if_new=True)
    except Exception as e:
        log_error(f"Update check failed: {e}")


def _run_update_check_after_model_ready(model_ready_event: threading.Event) -> None:
    """Run update check only after Whisper warm-up finishes."""
    try:
        model_ready_event.wait(timeout=600)
        check_for_update(open_url_if_new=True)
    except Exception as e:
        log_error(f"Update check failed: {e}")


def main() -> None:
    # Ensure we are in the right directory
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    try:
        # Initialize the core application logic
        logic_app = SVoiceRecApp(str(get_config_path()))

        # Initialize the Menu Bar interface
        menu_app = ClickNSpeakApp(logic_app)

        # Link them
        logic_app.set_menu_bar(menu_app)

        # Ensure accessibility permissions are requested and guide user if missing
        ensure_accessibility_permission()

        # Start model warm-up early to reduce first-run transcription latency.
        logic_app.start_model_warmup()

        log_info("Click-n-speak is running in the menu bar...")
        s = get_ui_strings(get_primary_language(logic_app.config))
        send_notification("Click-n-speak", s["started_title"], s["started_body"])

        # Start hotkey listener
        logic_app.hotkey_handler.start()

        # Check for updates once per session in background (after warm-up).
        threading.Thread(
            target=_run_update_check_after_model_ready,
            args=(logic_app.model_ready_event,),
            daemon=True,
        ).start()

        # Run the Menu Bar app (this is the main loop)
        menu_app.run()

    except Exception as e:
        log_error(f"Failed to start application: {e}")
        sys.exit(1)


if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()
    main()
