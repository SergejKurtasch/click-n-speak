"""Process watchdog utilities.

macOS has no equivalent of Linux's `PR_SET_PDEATHSIG`, so a multiprocessing
child can outlive its parent if the parent is killed abruptly (SIGKILL,
segfault, Force Quit, NSApp.terminate without our cleanup path). This module
provides two independent safety nets that run *inside* the child process:

1. `install_parent_death_watchdog` — primary defense. Uses kqueue's
   `EVFILT_PROC` + `NOTE_EXIT` to get a kernel-level notification the
   instant the parent dies. Reacts within ~10 ms.
2. A fallback polling thread that periodically checks `os.getppid() == 1`
   (process has been reparented to launchd). Reacts within ~2 s. Kept as
   a backup in case kqueue is unavailable (rare, but cheap insurance).

Both run as daemon threads and call `os._exit(0)` on trigger so the child
dies hard without relying on Python-level cleanup.

Additionally `sweep_orphan_children` scans for orphaned Click-n-speak
helper processes left behind by previous crashed sessions and kills them
before a new instance starts loading its own models.
"""

from __future__ import annotations

import os
import select
import sys
import threading
import time
from typing import Callable, Optional


_PPID_POLL_INTERVAL_SECONDS = 2.0


def _default_log(msg: str) -> None:
    """Best-effort log: prefer project logger, fall back to stderr.

    Used from the multiprocessing child where a logger import may fail during
    interpreter teardown. Keeps the module dependency-free for reuse.
    """
    try:
        from .utils import log_info  # local import avoids circular at module load
        log_info(msg)
    except Exception:
        try:
            print(f"[watchdog] {msg}", file=sys.stderr, flush=True)
        except Exception:
            pass


def _default_exit(reason: str) -> None:
    """Hard exit that bypasses atexit/finally — we want to die fast."""
    _default_log(f"child exiting: {reason}, pid={os.getpid()}")
    os._exit(0)


def install_parent_death_watchdog(
    on_parent_death: Optional[Callable[[str], None]] = None,
    log: Optional[Callable[[str], None]] = None,
) -> None:
    """Start watchdog threads that terminate this process when its parent dies.

    Safe to call from any process; intended for multiprocessing children.
    Starts two daemon threads:
      - kqueue watcher (primary, kernel-driven, fires within ~10 ms).
      - PPID poller (fallback, fires within ~2 s if PPID becomes 1).

    `on_parent_death` is called with a short reason string identifying which
    sensor tripped. `log` can override the default log backend (useful for tests).
    """
    exit_fn = on_parent_death or _default_exit
    log_fn = log or _default_log
    parent_pid = os.getppid()

    log_fn(
        f"installing parent-death watchdog: pid={os.getpid()} ppid={parent_pid} "
        f"pgid={os.getpgrp()}"
    )

    # If we were already orphaned before the watchdog installed, exit now.
    # parent_pid <= 1 also covers the theoretical 0 return on unusual kernels.
    if parent_pid <= 1:
        exit_fn("already-orphaned")
        return

    threading.Thread(
        target=_kqueue_watcher,
        args=(parent_pid, exit_fn, log_fn),
        name="parent-death-kqueue",
        daemon=True,
    ).start()

    threading.Thread(
        target=_ppid_poller,
        args=(parent_pid, exit_fn, log_fn),
        name="parent-death-poll",
        daemon=True,
    ).start()


def _kqueue_watcher(
    parent_pid: int,
    exit_fn: Callable[[str], None],
    log_fn: Callable[[str], None],
) -> None:
    """Block on kqueue until NOTE_EXIT fires for the parent PID."""
    try:
        kq = select.kqueue()
        kev = select.kevent(
            parent_pid,
            filter=select.KQ_FILTER_PROC,
            flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
            fflags=select.KQ_NOTE_EXIT,
        )
        kq.control([kev], 0, 0)
        # Blocks indefinitely until the parent exits (or our process is killed).
        events = kq.control(None, 1, None)
        for ev in events:
            if ev.ident == parent_pid and (ev.fflags & select.KQ_NOTE_EXIT):
                break
    except Exception as e:
        log_fn(f"kqueue watcher failed: {e!r} — relying on PPID poller fallback")
        return
    exit_fn("kqueue-NOTE_EXIT")


def _ppid_poller(
    parent_pid: int,
    exit_fn: Callable[[str], None],
    log_fn: Callable[[str], None],
) -> None:
    """Poll getppid() periodically; exit if it changes (parent died, we were reparented)."""
    while True:
        try:
            current = os.getppid()
            # Parent has died — we were reparented (usually to launchd, PID 1).
            # A changed PPID covers the launchd=1 case automatically.
            if current != parent_pid:
                exit_fn(f"ppid-changed={current}")
                return
        except Exception:
            pass
        time.sleep(_PPID_POLL_INTERVAL_SECONDS)


def sweep_orphan_children(
    app_name_fragment: str = "Click-n-speak",
    self_pid: Optional[int] = None,
) -> int:
    """Kill orphaned Click-n-speak helper processes from previous sessions.

    An orphan here means: a multiprocessing helper (`spawn_main` /
    `resource_tracker`) whose executable path contains `app_name_fragment`
    and whose parent is launchd (PID 1). Called at startup so accumulated
    ghosts from crashed prior sessions don't keep hogging multiple GB of RAM.

    Returns the number of processes killed.
    """
    self_pid = self_pid if self_pid is not None else os.getpid()
    killed = 0
    try:
        import psutil  # type: ignore
    except ImportError:
        return 0

    for proc in psutil.process_iter(["pid", "ppid", "name", "cmdline", "exe"]):
        try:
            info = proc.info
            pid = info.get("pid")
            if pid == self_pid or pid == 1:
                continue
            if info.get("ppid") != 1:
                continue

            # Match by executable, command line, or process name. On sandboxed
            # macOS runs `cmdline` and `exe` may be empty (AccessDenied returns
            # []/""), and `name` is the only surviving identifier.
            exe = info.get("exe") or ""
            cmdline = info.get("cmdline") or []
            name = info.get("name") or ""
            haystack = exe + " " + " ".join(cmdline) + " " + name
            if app_name_fragment not in haystack:
                continue

            # Only kill multiprocessing helpers — never a live main bundle
            # (a real running instance would have its own PGID leader).
            is_helper = any(
                marker in haystack
                for marker in (
                    "multiprocessing.spawn",
                    "multiprocessing.resource_tracker",
                    "--multiprocessing-fork",
                )
            )
            if not is_helper:
                continue

            try:
                proc.kill()
                killed += 1
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
        except Exception:
            continue

    return killed


_nsapp_terminate_observer = None  # strong reference so ObjC doesn't release it
_nsapp_terminate_observer_class = None  # ObjC class can only be defined once
_nsapp_terminate_cleanup_fn: Optional[Callable[[], None]] = None


def install_nsapp_terminate_observer(cleanup_fn: Callable[[], None]) -> bool:
    """Call `cleanup_fn` just before NSApplication terminates.

    Covers the path where rumps' built-in Cmd+Q / macOS "Quit" invokes
    `NSApp.terminate:` directly, bypassing our own `quit_application()` menu
    handler. Without this, the transcriber child still dies (watchdog),
    but atexit-based cleanup in the parent is skipped mid-flight.

    Uses NSApplicationWillTerminateNotification rather than swizzling the
    existing NSApplicationDelegate (rumps owns that), so it plays nicely
    with whatever else AppKit has subscribed.

    Returns True on success; False if AppKit is not available (e.g. during
    headless tests).
    """
    global _nsapp_terminate_observer, _nsapp_terminate_observer_class
    global _nsapp_terminate_cleanup_fn
    try:
        from AppKit import NSApplicationWillTerminateNotification
        from Foundation import NSNotificationCenter, NSObject
        import objc  # noqa: F401 — required to subclass NSObject
    except ImportError:
        return False

    center = NSNotificationCenter.defaultCenter()

    # Idempotent: if called twice (e.g. app relaunch in-process, or a test
    # that toggles the observer), drop the previous registration so we don't
    # accumulate multiple callbacks for a single terminate notification.
    if _nsapp_terminate_observer is not None:
        try:
            center.removeObserver_(_nsapp_terminate_observer)
        except Exception:
            pass
        _nsapp_terminate_observer = None

    # Always store the latest callback — the ObjC class reads it through the
    # module global so one class definition can serve multiple installs.
    _nsapp_terminate_cleanup_fn = cleanup_fn

    # ObjC classes are global to the runtime and can only be defined once.
    # On the first call we create the class; on later calls we reuse it.
    if _nsapp_terminate_observer_class is None:
        class _TerminateObserver(NSObject):  # type: ignore[misc]
            def onTerminate_(self, _notification):
                fn = _nsapp_terminate_cleanup_fn
                if fn is None:
                    return
                try:
                    fn()
                except Exception:
                    # Must not raise into AppKit — we're on the teardown path.
                    pass

        _nsapp_terminate_observer_class = _TerminateObserver

    observer = _nsapp_terminate_observer_class.alloc().init()
    center.addObserver_selector_name_object_(
        observer, "onTerminate:", NSApplicationWillTerminateNotification, None
    )
    # Keep a strong reference; otherwise ObjC may release it and the selector
    # call will land on a dead object.
    _nsapp_terminate_observer = observer
    return True


def ensure_own_process_group() -> bool:
    """Move the current process into its own group so killpg reaches every descendant.

    After this, PGID == PID and any child spawned afterwards inherits this PGID
    (unless it calls setpgid itself). `os.killpg(os.getpgrp(), SIGKILL)` will
    then reliably kill every descendant, including multiprocessing
    resource_tracker and spawn_main workers.

    Returns True if the group was set (or already correct), False otherwise.
    """
    try:
        pid = os.getpid()
        if os.getpgrp() == pid:
            return True
        os.setpgrp()
        return True
    except (OSError, AttributeError):
        return False


if __name__ == "__main__":
    # Manual smoke test: `python -m src.process_watchdog` prints parent info and exits.
    print(f"pid={os.getpid()} ppid={os.getppid()} pgid={os.getpgrp()}")
    sys.exit(0)
