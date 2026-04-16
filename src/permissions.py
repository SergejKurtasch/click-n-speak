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
    """
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio  # type: ignore
    except Exception as exc:
        log.error("AVFoundation not available, opening microphone settings: %s", exc)
        open_microphone_settings()
        return False

    event = threading.Event()
    result: list[bool] = [False]

    def _handler(granted: bool) -> None:
        result[0] = bool(granted)
        log.info("Microphone permission response: granted=%s", result[0])
        event.set()

    AVCaptureDevice.requestAccessForMediaType_completionHandler_(AVMediaTypeAudio, _handler)
    event.wait(timeout=timeout)
    return result[0]


def open_microphone_settings() -> None:
    """Open System Settings on the Microphone privacy pane."""
    import subprocess
    subprocess.run(
        ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"],
        check=False,
    )


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


def open_accessibility_settings() -> None:
    """Open System Settings on the Accessibility privacy pane."""
    import subprocess
    subprocess.run(
        ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"],
        check=False,
    )


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
# Aggregate status
# ---------------------------------------------------------------------------

def all_permissions_granted() -> bool:
    """Return True if both microphone and accessibility are granted."""
    return check_microphone() == "granted" and check_accessibility()
