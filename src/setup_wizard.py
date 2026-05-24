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

from . import i18n
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
        permissions_needed.append(i18n.t("wizard.perm_item_mic"))
    if need_acc:
        permissions_needed.append(i18n.t("wizard.perm_item_access"))
    if need_im:
        permissions_needed.append(i18n.t("wizard.perm_item_input"))

    perm_list = "\n".join(f"  • {p}" for p in permissions_needed)
    perm_word = i18n.plural("wizard.perm_word", total_steps)

    clicked = _alert(
        i18n.t("wizard.welcome_title"),
        i18n.t("wizard.welcome_body", total_steps=total_steps, perm_word=perm_word, perm_list=perm_list),
        [i18n.t("btn.lets_go"), i18n.t("btn.skip")],
    )
    if clicked != 0:
        log.info("User skipped the setup wizard.")
        mark_setup_done()
        return

    step = 0

    # ── Step: Microphone ─────────────────────────────────────────────────────
    if need_mic:
        step += 1
        label = i18n.t("wizard.step_label", step=step, total=total_steps)

        if mic == "denied":
            clicked = _alert(
                i18n.t("wizard.perm_mic_title", label=label),
                i18n.t("wizard.perm_mic_denied_body"),
                [i18n.t("btn.open_settings"), i18n.t("btn.skip")],
            )
            if clicked == 0:
                from .permissions import open_microphone_settings
                open_microphone_settings()
        else:
            _alert(
                i18n.t("wizard.perm_mic_title", label=label),
                i18n.t("wizard.perm_mic_first_body"),
                [i18n.t("btn.request_access")],
            )
            granted = request_microphone_sync(timeout=30.0)
            if not granted:
                clicked = _alert(
                    i18n.t("wizard.perm_mic_not_granted_title"),
                    i18n.t("wizard.perm_mic_not_granted_body"),
                    [i18n.t("btn.open_settings"), i18n.t("btn.continue_anyway")],
                )
                if clicked == 0:
                    from .permissions import open_microphone_settings
                    open_microphone_settings()
            else:
                _alert(
                    i18n.t("wizard.perm_mic_granted_title"),
                    i18n.t("wizard.perm_mic_granted_body"),
                    [i18n.t("btn.next")],
                )

    # ── Step: Accessibility ──────────────────────────────────────────────────
    if need_acc:
        step += 1
        label = i18n.t("wizard.step_label", step=step, total=total_steps)

        clicked = _alert(
            i18n.t("wizard.perm_access_title", label=label),
            i18n.t("wizard.perm_access_body"),
            [i18n.t("btn.open_settings"), i18n.t("btn.skip")],
        )
        if clicked == 0:
            open_accessibility_settings()
            _wait_for_permission_with_dialog(
                title=i18n.t("wizard.perm_access_waiting_title"),
                check_fn=check_accessibility,
                timeout=_ACCESSIBILITY_WAIT_TIMEOUT,
                granted_title=i18n.t("wizard.perm_access_granted_title"),
                granted_body=i18n.t("wizard.perm_access_granted_body"),
            )
        else:
            log.info("User skipped accessibility setup.")

    # ── Step: Input Monitoring ───────────────────────────────────────────────
    if need_im:
        step += 1
        label = i18n.t("wizard.step_label", step=step, total=total_steps)

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
                i18n.t("wizard.perm_input_title", label=label),
                i18n.t("wizard.perm_input_body"),
                [i18n.t("btn.open_settings"), i18n.t("btn.skip")],
            )
            if clicked == 0:
                open_input_monitoring_settings()
                _wait_for_permission_with_dialog(
                    title=i18n.t("wizard.perm_input_waiting_title"),
                    check_fn=check_input_monitoring,
                    timeout=_INPUT_MONITORING_WAIT_TIMEOUT,
                    granted_title=i18n.t("wizard.perm_input_granted_title"),
                    granted_body=i18n.t("wizard.perm_input_granted_body"),
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
            i18n.t("wizard.all_set_title"),
            i18n.t("wizard.all_set_body"),
            [i18n.t("btn.restart_now"), i18n.t("btn.later")],
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
            missing.append(i18n.t("wizard.missing_mic"))
        if not acc_ok:
            missing.append(i18n.t("wizard.missing_access"))
        if not im_ok:
            missing.append(i18n.t("wizard.missing_input"))
        _alert(
            i18n.t("wizard.incomplete_title"),
            i18n.t("wizard.incomplete_body", missing=", ".join(missing)),
            [i18n.t("btn.ok")],
            style=2,
        )

    mark_setup_done()
    log.info("Setup wizard completed.")


def _wait_for_permission_with_dialog(
    *,
    title: str,
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

    def _poll() -> None:
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
            _alert(granted_title, granted_body, [i18n.t("btn.next")])
            return

    cancel[0] = True
    t.join(timeout=2.0)

    if not granted[0]:
        log.info("Permission not detected within timeout for: %s", title)
