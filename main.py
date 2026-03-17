import os
import sys
import threading

from src.app import SVoiceRecApp
from src.menu_bar import ClickNSpeakApp
from src.updater import check_for_update
from src.utils import ensure_accessibility_permission, get_config_path, log_error, log_info, send_notification


def _run_update_check_once() -> None:
    """Run update check once in background (non-blocking)."""
    try:
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

        log_info("Click-n-speak is running in the menu bar...")
        send_notification("Click-n-speak", "Started", "Press the hotkey to start recording or use the menu bar icon.")

        # Start hotkey listener
        logic_app.hotkey_handler.start()

        # Check for updates once per session in background
        threading.Thread(target=_run_update_check_once, daemon=True).start()

        # Run the Menu Bar app (this is the main loop)
        menu_app.run()

    except Exception as e:
        log_error(f"Failed to start application: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
