"""
First-launch permission setup wizard for Click-n-speak.

Shows a sequential NSAlert-based dialog flow that guides the user through
granting Microphone and Accessibility permissions. Runs on the main thread.

Wizard steps:
  1. Welcome — explains what the app does and what it needs
  2. Microphone — triggers the system permission dialog
  3. Accessibility — opens System Settings with step-by-step instructions
  4. Done — confirms the setup and explains how to re-open if needed
"""
import logging
import threading

from .permissions import (
    check_accessibility,
    check_microphone,
    mark_setup_done,
    open_accessibility_settings,
    request_microphone_sync,
    wait_for_accessibility,
)

log = logging.getLogger(__name__)

# How long (seconds) to wait for the user to grant accessibility in settings
_ACCESSIBILITY_WAIT_TIMEOUT = 120.0


def _alert(title: str, body: str, buttons: list[str], style: int = 1) -> int:
    """Show a synchronous NSAlert and return the index of the clicked button (0-based).

    style: 1 = informational (default), 2 = warning, 0 = critical
    """
    try:
        from AppKit import NSAlert  # type: ignore
        alert = NSAlert.alloc().init()
        alert.setAlertStyle_(style)
        alert.setMessageText_(title)
        alert.setInformativeText_(body)
        for btn in buttons:
            alert.addButtonWithTitle_(btn)
        # runModal returns 1000 for first button, 1001 for second, etc.
        response = alert.runModal()
        return response - 1000
    except Exception as exc:
        log.error("NSAlert failed: %s", exc)
        return 0  # treat as first button


def run_setup_wizard() -> None:
    """Run the full permission setup wizard on the main thread.

    Safe to call even if permissions are already granted — it will skip
    unnecessary steps and mark setup as done silently.
    """
    try:
        _run_wizard()
    except Exception as exc:
        log.error("Setup wizard failed: %s", exc)
        mark_setup_done()  # don't block the app on wizard crash


def _run_wizard() -> None:
    mic = check_microphone()
    acc = check_accessibility()

    need_mic = mic not in ("granted", "restricted")
    need_acc = not acc

    if not need_mic and not need_acc:
        log.info("All permissions already granted — skipping wizard.")
        mark_setup_done()
        return

    # ── Step 1: Welcome ──────────────────────────────────────────────────────
    permissions_needed = []
    if need_mic:
        permissions_needed.append("🎙 Microphone — to hear your speech")
    if need_acc:
        permissions_needed.append("⌨️ Accessibility — for hotkeys and text insertion")

    perm_list = "\n".join(f"  • {p}" for p in permissions_needed)

    clicked = _alert(
        "Welcome to Click-n-speak",
        f"To work correctly, the app needs the following permissions:\n\n"
        f"{perm_list}\n\n"
        f"The next screens will guide you through granting them. "
        f"This takes about 30 seconds.",
        ["Get Started", "Skip"],
    )
    if clicked != 0:
        log.info("User skipped the setup wizard.")
        mark_setup_done()
        return

    # ── Step 2: Microphone ───────────────────────────────────────────────────
    if need_mic:
        if mic == "denied":
            _alert(
                "Microphone Access Denied",
                "Microphone access was previously denied.\n\n"
                "Please go to:\n"
                "  System Settings → Privacy & Security → Microphone\n"
                "and enable Click-n-speak.",
                ["Open Settings", "Skip"],
            )
            from .permissions import open_microphone_settings
            open_microphone_settings()
        else:
            # undetermined — trigger the system dialog
            _alert(
                "🎙 Microphone Access",
                "Click-n-speak needs microphone access to transcribe your speech.\n\n"
                "Click \"Continue\" — a system dialog will appear asking you to "
                "allow microphone access. Click \"Allow\".",
                ["Continue"],
            )
            granted = request_microphone_sync(timeout=30.0)
            if not granted:
                _alert(
                    "Microphone Not Granted",
                    "Microphone access was not granted.\n\n"
                    "You can enable it later in:\n"
                    "  System Settings → Privacy & Security → Microphone\n\n"
                    "The app will open System Settings now.",
                    ["Open Settings", "Skip"],
                )
                from .permissions import open_microphone_settings
                open_microphone_settings()
            else:
                _alert(
                    "✅ Microphone Granted",
                    "Microphone access has been granted. Click-n-speak can now "
                    "hear your speech.",
                    ["Continue"],
                )

    # ── Step 3: Accessibility ────────────────────────────────────────────────
    if need_acc:
        clicked = _alert(
            "⌨️ Accessibility Access",
            "Accessibility is required for:\n"
            "  • Global hotkeys (Alt+Space to start/stop recording)\n"
            "  • Typing transcribed text into any app\n\n"
            "Click \"Open Settings\" — System Settings will open on the Accessibility "
            "page. Find \"Click-n-speak\" in the list and toggle it ON.\n\n"
            "Come back here and click \"Done\" when you've enabled it.",
            ["Open Settings", "Skip"],
        )

        if clicked == 0:
            open_accessibility_settings()

            # Poll in background; show a waiting dialog
            _wait_for_accessibility_with_dialog()
        else:
            log.info("User skipped accessibility setup.")

    # ── Step 4: Done ─────────────────────────────────────────────────────────
    mic_ok = check_microphone() == "granted"
    acc_ok = check_accessibility()

    if mic_ok and acc_ok:
        _alert(
            "✅ All Set!",
            "Click-n-speak is ready to use.\n\n"
            "Press Alt+Space to start recording. Press it again to stop "
            "and get your transcription.\n\n"
            "You can always check permissions from the menu bar icon → "
            "\"Check Permissions\".",
            ["Start Using Click-n-speak"],
        )
    else:
        missing = []
        if not mic_ok:
            missing.append("Microphone")
        if not acc_ok:
            missing.append("Accessibility")
        missing_str = " and ".join(missing)
        _alert(
            "⚠️ Setup Incomplete",
            f"The following permissions are still missing:\n  • {missing_str}\n\n"
            f"The app will still start, but some features won't work "
            f"until you grant the missing permissions.\n\n"
            f"You can retry anytime from the menu bar icon → \"Check Permissions\".",
            ["OK"],
            style=2,
        )

    mark_setup_done()
    log.info("Setup wizard completed.")


def _wait_for_accessibility_with_dialog() -> None:
    """Show a 'waiting' dialog while polling for accessibility in a background thread.

    Closes automatically when accessibility is detected or after timeout.
    """
    try:
        from AppKit import (  # type: ignore
            NSAlert,
            NSTimer,
            NSRunLoop,
            NSDefaultRunLoopMode,
            NSDate,
        )
    except ImportError:
        # Fallback: just wait silently
        wait_for_accessibility(timeout=_ACCESSIBILITY_WAIT_TIMEOUT)
        return

    # Use a simpler approach: short-poll loop on main thread with a progress alert
    granted = [False]
    cancel = [False]

    def _poll_thread():
        import time
        deadline = time.monotonic() + _ACCESSIBILITY_WAIT_TIMEOUT
        while time.monotonic() < deadline and not cancel[0]:
            if check_accessibility():
                granted[0] = True
                return
            time.sleep(1.0)

    t = threading.Thread(target=_poll_thread, daemon=True)
    t.start()

    # Show a non-modal progress dialog — use a simple runModal alert with a timer
    # that aborts it once accessibility is detected.
    alert = NSAlert.alloc().init()
    alert.setAlertStyle_(1)
    alert.setMessageText_("Waiting for Accessibility Permission…")
    alert.setInformativeText_(
        "Open System Settings → Privacy & Security → Accessibility.\n"
        "Find Click-n-speak and toggle it ON.\n\n"
        "This dialog will close automatically once access is granted."
    )
    alert.addButtonWithTitle_("I've Enabled It")
    alert.addButtonWithTitle_("Skip")

    # Pump the run loop until the poller detects the grant or user clicks
    loop = NSRunLoop.currentRunLoop()
    import time
    start = time.monotonic()

    while not granted[0] and (time.monotonic() - start) < _ACCESSIBILITY_WAIT_TIMEOUT:
        # Process pending events for 0.5 s
        limit = NSDate.dateWithTimeIntervalSinceNow_(0.5)
        loop.runMode_beforeDate_(NSDefaultRunLoopMode, limit)

        if granted[0]:
            log.info("Accessibility detected — closing wait dialog.")
            # Dismiss the alert programmatically
            try:
                from AppKit import NSApp  # type: ignore
                NSApp.abortModal()
            except Exception:
                pass
            _alert(
                "✅ Accessibility Granted",
                "Accessibility access has been granted. Hotkeys and text insertion are now active.",
                ["Continue"],
            )
            return

    cancel[0] = True
    t.join(timeout=2.0)

    if not granted[0]:
        log.info("Accessibility not detected within timeout.")
