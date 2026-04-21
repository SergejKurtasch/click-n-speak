"""
First-launch permission setup wizard for Click-n-speak.

Shows a sequential NSAlert-based dialog flow that guides the user through
granting Microphone, Accessibility, and Input Monitoring permissions.
Runs on the main thread.

Wizard steps:
  1. Welcome — explains what the app does and what it needs
  2. Microphone — triggers the system permission dialog
  3. Accessibility — opens System Settings, waits with polling loop
  4. Input Monitoring — opens System Settings, waits with polling loop
  5. Done — confirms setup
"""
import logging
import threading
import time

from .permissions import (
    check_accessibility,
    check_input_monitoring,
    check_input_monitoring_fast,
    check_microphone,
    mark_setup_done,
    open_accessibility_settings,
    open_input_monitoring_settings,
    request_microphone_sync,
    wait_for_accessibility,
)

log = logging.getLogger(__name__)

_ACCESSIBILITY_WAIT_TIMEOUT = 120.0
_INPUT_MONITORING_WAIT_TIMEOUT = 120.0

# Set to True while the wizard is running so background timers skip their notifications
_WIZARD_ACTIVE = False


def is_wizard_active() -> bool:
    return _WIZARD_ACTIVE


def _alert(title: str, body: str, buttons: list[str], style: int = 1) -> int:
    """Show a synchronous NSAlert and return the index of the clicked button (0-based)."""
    try:
        from AppKit import NSAlert  # type: ignore
        alert = NSAlert.alloc().init()
        alert.setAlertStyle_(style)
        alert.setMessageText_(title)
        alert.setInformativeText_(body)
        for btn in buttons:
            alert.addButtonWithTitle_(btn)
        return alert.runModal() - 1000
    except Exception as exc:
        log.error("NSAlert failed: %s", exc)
        return 0


def run_setup_wizard() -> None:
    """Run the full permission setup wizard on the main thread."""
    global _WIZARD_ACTIVE
    _WIZARD_ACTIVE = True
    try:
        _run_wizard()
    except Exception as exc:
        log.error("Setup wizard failed: %s", exc)
        mark_setup_done()
    finally:
        _WIZARD_ACTIVE = False


def _run_wizard() -> None:
    mic = check_microphone()
    acc = check_accessibility()
    # Use the fast TCC check (no CGEventTap created, no dialog triggered).
    # Falls back to False when TCC.db is inaccessible — we show the step and let
    # the step itself trigger the native dialog at the right moment.
    im = check_input_monitoring_fast()

    need_mic = mic not in ("granted", "restricted")
    need_acc = not acc
    need_im = not im

    if not need_mic and not need_acc and not need_im:
        log.info("All permissions already granted — skipping wizard.")
        mark_setup_done()
        return

    # Count total steps for progress display
    total_steps = sum([need_mic, need_acc, need_im])

    # ── Welcome ──────────────────────────────────────────────────────────────
    permissions_needed = []
    if need_mic:
        permissions_needed.append("🎙  Microphone — to record your speech")
    if need_acc:
        permissions_needed.append("⌨️  Accessibility — to type text into any app")
    if need_im:
        permissions_needed.append("🔍  Input Monitoring — for the global hotkey (Alt+Space)")

    perm_list = "\n".join(f"  • {p}" for p in permissions_needed)

    clicked = _alert(
        "Welcome to Click-n-speak",
        f"The app needs {total_steps} permission{'s' if total_steps > 1 else ''} to work:\n\n"
        f"{perm_list}\n\n"
        f"Each step opens System Settings. Follow the on-screen instructions — "
        f"this takes about a minute.",
        ["Let's Go", "Skip"],
    )
    if clicked != 0:
        log.info("User skipped the setup wizard.")
        mark_setup_done()
        return

    step = 0

    # ── Step: Microphone ─────────────────────────────────────────────────────
    if need_mic:
        step += 1
        label = f"Step {step} of {total_steps}"

        if mic == "denied":
            _alert(
                f"🎙  Microphone Access  ({label})",
                "Microphone access was previously denied.\n\n"
                "System Settings will open. Find Click-n-speak under Microphone "
                "and toggle it ON.",
                ["Open Settings", "Skip"],
            )
            from .permissions import open_microphone_settings
            open_microphone_settings()
        else:
            _alert(
                f"🎙  Microphone Access  ({label})",
                "Click-n-speak needs to hear your speech.\n\n"
                "Click \"Request Access\" — macOS will show a permission dialog. "
                "Click Allow.",
                ["Request Access"],
            )
            granted = request_microphone_sync(timeout=30.0)
            if not granted:
                _alert(
                    "Microphone Not Granted",
                    "Microphone access was not granted. You can enable it later in:\n"
                    "  System Settings → Privacy & Security → Microphone\n\n"
                    "Opening System Settings now.",
                    ["Open Settings", "Continue Anyway"],
                )
                from .permissions import open_microphone_settings
                open_microphone_settings()
            else:
                _alert(
                    "✅ Microphone Granted",
                    "Done! Click-n-speak can now hear your speech.",
                    ["Next →"],
                )

    # ── Step: Accessibility ──────────────────────────────────────────────────
    if need_acc:
        step += 1
        label = f"Step {step} of {total_steps}"

        clicked = _alert(
            f"⌨️  Accessibility Access  ({label})",
            "Accessibility lets Click-n-speak type transcribed text into any app.\n\n"
            "Click \"Open Settings\" — System Settings will open on the Accessibility page.\n\n"
            "  1. Find Click-n-speak in the list\n"
            "  2. Toggle it ON\n"
            "  3. Come back here — this dialog closes automatically.",
            ["Open Settings", "Skip"],
        )
        if clicked == 0:
            open_accessibility_settings()
            _wait_for_permission_with_dialog(
                title="Waiting for Accessibility…",
                body=(
                    "System Settings → Privacy & Security → Accessibility\n\n"
                    "Find Click-n-speak and toggle it ON.\n\n"
                    "This dialog closes automatically once access is granted."
                ),
                check_fn=check_accessibility,
                timeout=_ACCESSIBILITY_WAIT_TIMEOUT,
                granted_title="✅ Accessibility Granted",
                granted_body="Accessibility access confirmed. Text injection is now active.",
            )
        else:
            log.info("User skipped accessibility setup.")

    # ── Step: Input Monitoring ───────────────────────────────────────────────
    if need_im:
        step += 1
        label = f"Step {step} of {total_steps}"

        # Trigger the native macOS permission dialog NOW (first CGEventTap attempt).
        # This must happen before we show any wizard instructions, so the system
        # dialog appears while the user reads our guidance — not earlier during
        # the wizard preamble.
        already_granted = check_input_monitoring()

        if already_granted:
            log.info("Input Monitoring already granted — skipping prompt.")
        else:
            # Dialog may have just appeared in the background (first-ever request),
            # or was previously denied (dialog won't appear again — go to Settings).
            clicked = _alert(
                f"🔍  Input Monitoring  ({label})",
                "Input Monitoring lets Click-n-speak detect the global hotkey (Alt+Space).\n\n"
                "macOS should be showing a permission dialog right now — click Allow in it.\n\n"
                "If no dialog appeared (permission was previously denied), "
                "click \"Open Settings\" to enable it manually.",
                ["Open Settings", "Skip"],
            )
            if clicked == 0:
                open_input_monitoring_settings()
                _wait_for_permission_with_dialog(
                    title="Waiting for Input Monitoring…",
                    body=(
                        "Did a system dialog appear? Click Allow in it.\n\n"
                        "Or in System Settings → Privacy & Security → Input Monitoring:\n"
                        "  • If Click-n-speak is listed with toggle OFF → toggle it ON\n"
                        "  • If Click-n-speak is not listed → close this dialog, "
                        "quit and relaunch the app — macOS will ask again\n\n"
                        "This dialog closes automatically once access is granted."
                    ),
                    check_fn=check_input_monitoring,
                    timeout=_INPUT_MONITORING_WAIT_TIMEOUT,
                    granted_title="✅ Input Monitoring Granted",
                    granted_body="Input Monitoring confirmed. The Alt+Space hotkey is now active.",
                )
            else:
                log.info("User skipped input monitoring setup.")

    # ── Done ─────────────────────────────────────────────────────────────────
    mic_ok = check_microphone() == "granted"
    acc_ok = check_accessibility()
    im_ok = check_input_monitoring()

    if mic_ok and acc_ok and im_ok:
        # Permissions were just granted in this session — the pynput listener can't
        # start safely until the process is relaunched (macOS 15+ TSM thread check).
        clicked = _alert(
            "✅ All Set — One Last Step",
            "All permissions are granted.\n\n"
            "Click-n-speak needs to restart once to activate the global hotkey "
            "(Alt+Space). After the restart, everything will work immediately.",
            ["Restart Now", "Later"],
        )
        mark_setup_done()
        log.info("Setup wizard completed. User chose: %s", "restart" if clicked == 0 else "later")
        if clicked == 0:
            from .utils import relaunch_app
            relaunch_app()
        return
    else:
        missing = []
        if not mic_ok:
            missing.append("Microphone")
        if not acc_ok:
            missing.append("Accessibility")
        if not im_ok:
            missing.append("Input Monitoring")
        _alert(
            "⚠️ Setup Incomplete",
            f"Still missing: {', '.join(missing)}\n\n"
            f"The app will start, but some features won't work until "
            f"you grant the remaining permissions.\n\n"
            f"Retry anytime: menu bar icon → Check Permissions.",
            ["OK"],
            style=2,
        )

    mark_setup_done()
    log.info("Setup wizard completed.")


def _wait_for_permission_with_dialog(
    *,
    title: str,
    body: str,
    check_fn,
    timeout: float,
    granted_title: str,
    granted_body: str,
) -> None:
    """Poll until check_fn() returns True or timeout elapses.

    Drives the main run loop in 0.5s ticks so AppKit events keep processing.
    Shows a confirmation alert when the permission is detected.
    """
    try:
        from AppKit import NSRunLoop, NSDefaultRunLoopMode, NSDate  # type: ignore
    except ImportError:
        # Headless fallback (e.g. tests without AppKit)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if check_fn():
                return
            time.sleep(1.0)
        return

    granted = [False]
    cancel = [False]

    def _poll():
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and not cancel[0]:
            if check_fn():
                granted[0] = True
                return
            time.sleep(1.0)

    t = threading.Thread(target=_poll, daemon=True)
    t.start()

    loop = NSRunLoop.currentRunLoop()
    start = time.monotonic()

    while not granted[0] and (time.monotonic() - start) < timeout:
        limit = NSDate.dateWithTimeIntervalSinceNow_(0.5)
        loop.runMode_beforeDate_(NSDefaultRunLoopMode, limit)

        if granted[0]:
            log.info("%s detected.", title)
            _alert(granted_title, granted_body, ["Next →"])
            return

    cancel[0] = True
    t.join(timeout=2.0)

    if not granted[0]:
        log.info("Permission not detected within timeout for: %s", title)
