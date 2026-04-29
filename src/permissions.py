"""
macOS permission helpers: check and request Microphone and Accessibility access.
Used by the setup wizard and the menu bar status item.
"""
import logging
import threading
from pathlib import Path

log = logging.getLogger(__name__)

# Sentinel file: presence means the first-launch wizard was completed.
_SETUP_FLAG = (
    Path.home() / "Library" / "Application Support" / "Click-n-speak" / "setup_done"
)

# AVAuthorizationStatus constants (mirrors AVFoundation enum)
_AV_NOT_DETERMINED = 0
_AV_RESTRICTED = 1
_AV_DENIED = 2
_AV_AUTHORIZED = 3


# ---------------------------------------------------------------------------
# Setup-done flag
# ---------------------------------------------------------------------------

def is_setup_done() -> bool:
    """Return True if the first-launch wizard has already been completed."""
    return _SETUP_FLAG.exists()


def mark_setup_done() -> None:
    """Record that the setup wizard has been completed."""
    _SETUP_FLAG.parent.mkdir(parents=True, exist_ok=True)
    _SETUP_FLAG.touch(exist_ok=True)


def reset_setup() -> None:
    """Remove the flag so the wizard runs again on next launch (for debugging)."""
    if _SETUP_FLAG.exists():
        _SETUP_FLAG.unlink()


# ---------------------------------------------------------------------------
# Microphone
# ---------------------------------------------------------------------------

def check_microphone() -> str:
    """Return the current microphone authorization status.

    Returns one of: 'granted', 'denied', 'restricted', 'undetermined'.
    Falls back to 'undetermined' if AVFoundation is unavailable.
    """
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio  # type: ignore
        status = int(AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio))
        return {
            _AV_AUTHORIZED: "granted",
            _AV_DENIED: "denied",
            _AV_RESTRICTED: "restricted",
        }.get(status, "undetermined")
    except Exception as exc:
        log.warning("Could not check microphone permission: %s", exc)
        return "undetermined"


def request_microphone_sync(timeout: float = 30.0) -> bool:
    """Trigger the system microphone permission dialog and block until the user responds.

    Returns True if the user granted access, False otherwise.
    Falls back to opening System Settings if AVFoundation is unavailable.

    Drives the NSRunLoop in 0.5 s ticks so AppKit events keep processing while
    waiting — avoids a hard block on the main thread.
    """
    import time as _time

    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio  # type: ignore
    except Exception as exc:
        log.error("AVFoundation not available, opening microphone settings: %s", exc)
        open_microphone_settings()
        return False

    result: list[bool] = [False]
    done: list[bool] = [False]

    def _handler(granted: bool) -> None:
        result[0] = bool(granted)
        done[0] = True
        log.info("Microphone permission response: granted=%s", result[0])

    AVCaptureDevice.requestAccessForMediaType_completionHandler_(AVMediaTypeAudio, _handler)

    try:
        from AppKit import NSRunLoop, NSDefaultRunLoopMode, NSDate  # type: ignore
        loop = NSRunLoop.currentRunLoop()
        start = _time.monotonic()
        while not done[0] and (_time.monotonic() - start) < timeout:
            limit = NSDate.dateWithTimeIntervalSinceNow_(0.5)
            loop.runMode_beforeDate_(NSDefaultRunLoopMode, limit)
    except ImportError:
        # Headless fallback (tests / non-AppKit environment)
        deadline = _time.monotonic() + timeout
        while not done[0] and _time.monotonic() < deadline:
            _time.sleep(0.5)

    return result[0]


def open_microphone_settings() -> None:
    """Open System Settings on the Microphone privacy pane."""
    import subprocess
    subprocess.run(
        ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"],
        check=False,
    )
    _activate_system_settings()


# ---------------------------------------------------------------------------
# Accessibility
# ---------------------------------------------------------------------------

def check_accessibility() -> bool:
    """Return True if the process is a trusted accessibility client."""
    try:
        from ApplicationServices import AXIsProcessTrusted  # type: ignore
        return bool(AXIsProcessTrusted())
    except Exception as exc:
        log.warning("Could not check accessibility permission: %s", exc)
        return True  # assume granted if we cannot check


def _activate_system_settings() -> None:
    import threading

    def _do_activate() -> None:
        import time
        time.sleep(0.5)
        try:
            from AppKit import NSWorkspace, NSApplicationActivateIgnoringOtherApps  # type: ignore
            for app in NSWorkspace.sharedWorkspace().runningApplications():
                bundle = app.bundleIdentifier() or ""
                if "systempreferences" in bundle or "systemsettings" in bundle:
                    app.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
                    return
        except Exception as exc:
            log.debug("Could not activate System Settings: %s", exc)

    threading.Thread(target=_do_activate, daemon=True).start()


def open_accessibility_settings() -> None:
    """Open System Settings on the Accessibility privacy pane."""
    import subprocess
    subprocess.run(
        ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"],
        check=False,
    )
    _activate_system_settings()


def wait_for_accessibility(timeout: float = 120.0, poll_interval: float = 1.0) -> bool:
    """Poll until accessibility is granted or *timeout* seconds elapse."""
    import time
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check_accessibility():
            return True
        time.sleep(poll_interval)
    return False


# ---------------------------------------------------------------------------
# Input Monitoring (macOS 15+ requires this for CGEventTap / global hotkeys)
# ---------------------------------------------------------------------------

def check_input_monitoring() -> bool:
    """Return True if the process can create a keyboard CGEventTap.

    On macOS 15+ (Sequoia / Darwin 24+) Input Monitoring is a separate TCC
    permission from Accessibility.  CGEventTapCreate returns None silently
    when it is missing, causing pynput's listener to exit immediately.
    """
    try:
        from Quartz import (  # type: ignore
            CGEventTapCreate,
            CFMachPortInvalidate,
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            CGEventMaskBit,
            kCGEventKeyDown,
        )

        def _cb(proxy, type_, event, refcon):
            return event

        tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            CGEventMaskBit(kCGEventKeyDown),
            _cb,
            None,
        )
        if tap is not None:
            CFMachPortInvalidate(tap)
            return True
        return False
    except Exception as exc:
        log.warning("Could not check input monitoring: %s", exc)
        return False  # assume denied if we can't verify — safer than assuming granted


def check_input_monitoring_fast() -> bool:
    """Check Input Monitoring permission without triggering the macOS permission dialog.

    Reads TCC.db directly via sqlite3.  Returns False if the DB is inaccessible
    (no Full Disk Access) — the caller should then show the step and let
    check_input_monitoring() trigger the native dialog at the right moment.
    """
    import subprocess
    tcc_db = (
        Path.home() / "Library" / "Application Support" / "com.apple.TCC" / "TCC.db"
    )
    if not tcc_db.exists():
        return False
    try:
        result = subprocess.run(
            [
                "sqlite3", "-readonly", str(tcc_db),
                "SELECT auth_value FROM access "
                "WHERE service='kTCCServiceListenEvent' "
                "AND (client='com.sergej.clicknspeak' OR client LIKE '%python%') LIMIT 1;",
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )
        # auth_value=2 means "allowed"
        return result.returncode == 0 and result.stdout.strip() == "2"
    except Exception as exc:
        log.warning("TCC fast-check failed (non-critical): %s", exc)
        return False


def open_input_monitoring_settings() -> None:
    """Open System Settings on the Input Monitoring privacy pane."""
    import subprocess
    subprocess.run(
        [
            "open",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ],
        check=False,
    )
    _activate_system_settings()


# ---------------------------------------------------------------------------
# Aggregate status
# ---------------------------------------------------------------------------

def all_permissions_granted() -> bool:
    """Return True if microphone, accessibility, and input monitoring are all granted.

    Uses check_input_monitoring() (CGEventTap) rather than the fast TCC.db read because
    TCC.db is inaccessible on most Macs with SIP enabled, causing the fast check to always
    return False and triggering the setup wizard again on every launch.
    """
    return (
        check_microphone() == "granted"
        and check_accessibility()
        and check_input_monitoring()
    )
