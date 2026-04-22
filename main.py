import atexit
import fcntl
import os
import signal
import sys
import threading
from pathlib import Path

from src.app import SVoiceRecApp
from src.menu_bar import ClickNSpeakApp
from src.permissions import all_permissions_granted, is_setup_done, mark_setup_done
from src.updater import check_for_update
from src.utils import (
    get_config_path,
    get_primary_language,
    get_ui_strings,
    is_accessibility_trusted,
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


_LOCK_FILE: Path = Path.home() / "Library" / "Application Support" / "Click-n-speak" / ".instance.lock"
_lock_fd = None


def _acquire_instance_lock() -> bool:
    """Acquire an exclusive file lock so only one main instance runs at a time.

    Returns True if the lock was acquired (this is the primary instance).
    Returns False if another instance already holds the lock.
    A stale lock from a crashed process is automatically reclaimed because the
    OS releases file locks when a process dies.
    """
    global _lock_fd
    try:
        _LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        _lock_fd = open(_LOCK_FILE, "w")
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _lock_fd.write(str(os.getpid()))
        _lock_fd.flush()
        return True
    except (IOError, OSError):
        return False


def _release_instance_lock() -> None:
    global _lock_fd
    if _lock_fd is not None:
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_UN)
            _lock_fd.close()
        except Exception:
            pass
        _lock_fd = None


def main() -> None:
    # Ensure we are in the right directory
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    if not _acquire_instance_lock():
        log_error("Another Click-n-speak instance is already running. Exiting.")
        sys.exit(0)

    try:
        # Initialize the core application logic
        logic_app = SVoiceRecApp(str(get_config_path()))

        # Initialize the Menu Bar interface
        menu_app = ClickNSpeakApp(logic_app)

        # Link them
        logic_app.set_menu_bar(menu_app)

        # First-launch permission wizard: runs after the menu bar is visible.
        # Schedules on the main thread via menu_bar so NSAlert has an active NSApp.
        if not is_setup_done():
            menu_app.schedule_setup_wizard()
        elif not all_permissions_granted():
            # Wizard was completed before but permissions were revoked/missing.
            menu_app.schedule_setup_wizard()

        # Check current accessibility state (no blocking prompt — wizard handles it).
        trusted = is_accessibility_trusted()

        # Ensure full cleanup on any exit path.
        def _full_cleanup():
            try:
                logic_app.stop()
            except Exception:
                try:
                    logic_app.transcriber.stop()
                except Exception:
                    pass

        def _cleanup_and_exit():
            _full_cleanup()
            _release_instance_lock()

        atexit.register(_cleanup_and_exit)
        for _sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(_sig, lambda *_: (_cleanup_and_exit(), sys.exit(0)))

        # Start model warm-up early to reduce first-run transcription latency.
        logic_app.start_model_warmup()

        # Start background stability tasks (keep-alive and wake from sleep warmup)
        logic_app.start_keep_alive_timer()
        logic_app.start_wake_observer()

        log_info("Click-n-speak is running in the menu bar...")
        s = get_ui_strings(get_primary_language(logic_app.config))
        send_notification("Click-n-speak", s["started_title"], s["started_body"])

        if trusted:
            # Permissions already granted — start hotkeys immediately
            logic_app.hotkey_handler.start()
            log_info("Hotkey listener started (accessibility already granted).")
        else:
            # Wizard will guide user through permissions and prompt a relaunch.
            # Do NOT auto-start listener on permission change: pynput calls
            # TSMGetInputSourceProperty from its listener thread, which crashes
            # on macOS 15+ unless the process was started with permissions already granted.
            log_info("Accessibility not granted. Waiting for wizard + app restart.")

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

