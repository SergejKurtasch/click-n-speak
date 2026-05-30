import atexit
import fcntl
import os
import signal
import subprocess
import sys
import threading
from pathlib import Path

from src.app import SVoiceRecApp
from src.menu_bar import ClickNSpeakApp
from src import i18n as _i18n
from src.language_picker import show_if_needed as _show_language_picker_if_needed
from src.permissions import all_permissions_granted, is_setup_done, mark_setup_done
from src.process_watchdog import (
    ensure_own_process_group,
    install_nsapp_terminate_observer,
    sweep_orphan_children,
)
from src.updater import check_for_update
from src.utils import (
    get_config_path,
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


def _activate_existing_instance() -> None:
    """Bring the running Click-n-speak instance to the foreground and notify the user."""
    # Send a macOS notification so the user sees something happened.
    # i18n is not yet loaded (we exit before initialising the app), so use
    # the English strings directly — this is a rare edge-case path.
    send_notification(
        "Click-n-speak is already running",
        "The app is active in the menu bar.",
        "",
    )
    # Try to activate via AppKit (works when running as .app bundle).
    try:
        from AppKit import NSRunningApplication  # type: ignore
        bundle_id = "com.sergej.clicknspeak"
        apps = NSRunningApplication.runningApplicationsWithBundleIdentifier_(bundle_id)
        if apps:
            apps[0].activateWithOptions_(0)
            return
    except Exception:
        pass
    # Fallback for dev mode: find the process by name via psutil and use osascript.
    try:
        import psutil
        my_pid = os.getpid()
        for proc in psutil.process_iter(["pid", "cmdline"]):
            try:
                cmdline = " ".join(proc.info["cmdline"] or [])
                if proc.info["pid"] != my_pid and "click" in cmdline.lower() and "speak" in cmdline.lower():
                    subprocess.run(
                        ["osascript", "-e",
                         f'tell application "System Events" to set frontmost of '
                         f'(first process whose unix id is {proc.info["pid"]}) to true'],
                        timeout=2,
                        capture_output=True,
                    )
                    return
            except Exception:
                continue
    except Exception:
        pass


def main() -> None:
    # Ensure we are in the right directory
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    # Move into our own process group BEFORE spawning any children. Any child
    # (including multiprocessing resource_tracker + spawn_main) inherits this
    # PGID, which makes killpg(getpgrp(), SIGKILL) reach every descendant.
    ensure_own_process_group()

    # Reap orphaned transcriber helpers left behind by previous crashed sessions.
    # Each orphan can hold 2-4 GB of MLX model weights. Must run before we start
    # our own transcriber so we don't kill ourselves.
    try:
        reaped = sweep_orphan_children(self_pid=os.getpid())
        if reaped:
            log_info(f"Startup sweep: killed {reaped} orphaned helper process(es) from prior session(s).")
    except Exception as e:
        log_error(f"Startup orphan sweep failed: {e}")

    if not _acquire_instance_lock():
        log_info("Another Click-n-speak instance is already running. Exiting.")
        _activate_existing_instance()
        sys.exit(0)

    try:
        # Initialize the core application logic
        logic_app = SVoiceRecApp(str(get_config_path()))

        # Load locale BEFORE building the menu so all i18n.t() calls resolve correctly.
        # language_picker writes primary_language to config on first launch;
        # on subsequent launches the config already has the chosen language.
        _i18n.load(logic_app.config.get("primary_language", "en"))

        # Initialize the Menu Bar interface
        menu_app = ClickNSpeakApp(logic_app)

        # Link them
        logic_app.set_menu_bar(menu_app)

        # First-launch language picker + permission wizard.
        # Language picker runs before the wizard on first launch; subsequent launches
        # skip it (language_picker_done=True in config) and jump straight to wizard if needed.
        need_wizard = not is_setup_done() or not all_permissions_granted()
        if not logic_app.config.get("language_picker_done"):
            menu_app.schedule_language_picker(run_wizard_after=need_wizard)
        elif need_wizard:
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

        def _signal_exit(signum, _frame) -> None:
            log_info(f"Received signal {signum}, cleaning up and killing process group.")
            _cleanup_and_exit()
            # Kill entire process group so child processes (transcriber) die with us.
            # os.killpg covers what os._exit(0) misses: atexit is bypassed by both,
            # but killpg propagates the kill to daemon multiprocessing children.
            try:
                os.killpg(os.getpgrp(), signal.SIGKILL)
            except Exception:
                os._exit(0)

        # SIGHUP fires on terminal close / user logout; SIGQUIT on ctrl-\.
        # SIGABRT is intentionally NOT handled — it signals a fatal runtime
        # assertion (Python, ObjC, native lib) where trying to run cleanup
        # typically deadlocks or re-enters the failing code path.
        for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
            try:
                signal.signal(_sig, _signal_exit)
            except (OSError, ValueError) as e:
                log_error(f"Could not install handler for signal {_sig}: {e}")

        # Uncaught exceptions (main thread and background threads) must also run
        # cleanup — otherwise a crash in pynput/AppKit/MLX orphans the child.
        _default_excepthook = sys.excepthook

        def _excepthook(exc_type, exc, tb):
            log_error(f"Uncaught exception: {exc_type.__name__}: {exc}")
            try:
                _cleanup_and_exit()
            finally:
                try:
                    os.killpg(os.getpgrp(), signal.SIGKILL)
                except Exception:
                    _default_excepthook(exc_type, exc, tb)
                    os._exit(1)

        sys.excepthook = _excepthook

        def _thread_excepthook(args) -> None:
            # SystemExit / KeyboardInterrupt are cooperative exits — don't treat
            # subclasses (e.g. `class CleanExit(SystemExit)`) as crashes either.
            if issubclass(args.exc_type, (SystemExit, KeyboardInterrupt)):
                return
            log_error(
                f"Uncaught thread exception in {args.thread.name}: "
                f"{args.exc_type.__name__}: {args.exc_value}"
            )
            try:
                _cleanup_and_exit()
            finally:
                try:
                    os.killpg(os.getpgrp(), signal.SIGKILL)
                except Exception:
                    os._exit(1)

        threading.excepthook = _thread_excepthook

        # rumps' built-in Cmd+Q triggers NSApp.terminate: which bypasses our
        # menu-bar quit handler. Subscribe to NSApplicationWillTerminateNotification
        # so the transcriber child is always stopped on that path too.
        #
        # NOTE: we pass `_full_cleanup`, NOT `_cleanup_and_exit`. AppKit releases
        # the instance lock for us when the process exits; calling
        # `_release_instance_lock` here would close the fd while AppKit is still
        # mid-teardown and could race with atexit. Keep cleanup minimal on this
        # path — stop the transcriber and let normal exit handle the rest.
        install_nsapp_terminate_observer(_full_cleanup)

        # Start model warm-up early to reduce first-run transcription latency.
        logic_app.start_model_warmup()

        # Start background stability tasks (keep-alive and wake from sleep warmup)
        logic_app.start_keep_alive_timer()
        logic_app.start_wake_observer()

        log_info("Click-n-speak is running in the menu bar...")
        send_notification("Click-n-speak", _i18n.t("hud.started_title"), _i18n.t("hud.started_body"))

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

