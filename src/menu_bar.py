import os
import queue
import subprocess
import sys
import threading

import rumps

# ---------------------------------------------------------------------------
# Whisper model registry — ordered fastest → most accurate
# ---------------------------------------------------------------------------
WHISPER_MODELS = [
    ("Turbo",    "mlx-community/whisper-large-v3-turbo"),
    ("Large v3", "mlx-community/whisper-large-v3-mlx"),
    ("Medium",   "mlx-community/whisper-medium-mlx"),
    ("Small",    "mlx-community/whisper-small-mlx"),
    ("Base",     "mlx-community/whisper-base-mlx"),
]

_ICON_CACHED = "🟢"  # 🟢  — model is on disk, instant switch

from .phrase_history import get_last_phrases
from .updater import check_for_update
from .permissions import (
    check_input_monitoring,
    check_microphone,
    open_input_monitoring_settings,
    open_microphone_settings,
)
from .autostart import is_launch_at_login_enabled, set_launch_at_login
from .utils import (
    build_initial_prompt,
    copy_to_clipboard,
    deduplicate_prompt_terms,
    get_config_path,
    get_log_file_path,
    get_menu_icon_path,
    get_menu_item_icon_path,
    get_menubar_icon_path,
    get_primary_language,
    get_ui_strings,
    is_accessibility_trusted,
    LANG_PROMPTS,
    log_error,
    log_info,
    open_accessibility_settings,
    parse_prompt_terms,
    relaunch_app,
    save_config_to_disk,
    send_notification,
)


# ---------------------------------------------------------------------------
# Language Selection Panel (NSPanel — stays open across multiple clicks)
# ---------------------------------------------------------------------------

LANGS = ["ru", "en", "de", "es", "fr"]
LANG_LABELS = {
    "ru": "RU — Russian",
    "en": "EN — English",
    "de": "DE — German",
    "es": "ES — Spanish",
    "fr": "FR — French",
}
# LANG_PROMPTS is now defined in utils.py and imported above.

try:
    from Foundation import NSObject
    from AppKit import NSView, NSMakeRect
    import objc as _objc

    class _LangMenuController(NSObject):
        """Builds the language selection NSMenu with sticky view-based items.

        NSMenuItem.setView_() prevents the menu from closing when buttons inside
        the view are clicked — the standard macOS pattern for multi-select menus.
        """

        @_objc.python_method
        def configure(self, config: dict, on_primary, on_additional) -> None:
            self._config = config
            self._on_primary = on_primary
            self._on_additional = on_additional
            self._primary_btns: dict = {}
            self._additional_btns: dict = {}

        @_objc.python_method
        def build_submenu(self):
            from AppKit import (
                NSMenu, NSMenuItem, NSButton, NSTextField, NSFont,
                NSButtonTypeRadio, NSButtonTypeSwitch,
                NSControlStateValueOn, NSControlStateValueOff,
            )

            VIEW_W = 220
            ROW_H = 22
            HEADER_H = 20
            MARGIN = 14

            menu = NSMenu.alloc().init()
            menu.setAutoenablesItems_(False)
            self._primary_btns = {}
            self._additional_btns = {}

            primary = self._config.get("primary_language", "ru")
            additional = list(self._config.get("additional_languages") or [])

            def _header_item(text: str) -> None:
                view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, VIEW_W, HEADER_H))
                lbl = NSTextField.alloc().initWithFrame_(
                    NSMakeRect(MARGIN, 2, VIEW_W - 2 * MARGIN, HEADER_H - 4)
                )
                lbl.setStringValue_(text)
                lbl.setBezeled_(False)
                lbl.setDrawsBackground_(False)
                lbl.setEditable_(False)
                lbl.setSelectable_(False)
                lbl.setFont_(NSFont.boldSystemFontOfSize_(11))
                view.addSubview_(lbl)
                mi = NSMenuItem.alloc().init()
                mi.setView_(view)
                mi.setEnabled_(False)
                menu.addItem_(mi)

            def _radio_item(idx: int, lang: str) -> None:
                view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, VIEW_W, ROW_H))
                btn = NSButton.alloc().initWithFrame_(
                    NSMakeRect(MARGIN, 1, VIEW_W - 2 * MARGIN, ROW_H - 2)
                )
                btn.setButtonType_(NSButtonTypeRadio)
                btn.setTitle_(LANG_LABELS[lang])
                btn.setState_(NSControlStateValueOn if lang == primary else NSControlStateValueOff)
                btn.setTarget_(self)
                btn.setAction_("primaryClicked:")
                btn.setTag_(idx)
                view.addSubview_(btn)
                self._primary_btns[lang] = btn
                mi = NSMenuItem.alloc().init()
                mi.setView_(view)
                menu.addItem_(mi)

            def _checkbox_item(idx: int, lang: str) -> None:
                view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, VIEW_W, ROW_H))
                btn = NSButton.alloc().initWithFrame_(
                    NSMakeRect(MARGIN, 1, VIEW_W - 2 * MARGIN, ROW_H - 2)
                )
                btn.setButtonType_(NSButtonTypeSwitch)
                btn.setTitle_(LANG_LABELS[lang])
                btn.setState_(NSControlStateValueOn if lang in additional else NSControlStateValueOff)
                btn.setTarget_(self)
                btn.setAction_("additionalClicked:")
                btn.setTag_(idx)
                view.addSubview_(btn)
                self._additional_btns[lang] = btn
                mi = NSMenuItem.alloc().init()
                mi.setView_(view)
                menu.addItem_(mi)

            _header_item("Primary Language")
            for i, lang in enumerate(LANGS):
                _radio_item(i, lang)

            menu.addItem_(NSMenuItem.separatorItem())
            _header_item("Additional Languages")
            for i, lang in enumerate(LANGS):
                _checkbox_item(i, lang)

            return menu

        def primaryClicked_(self, sender):
            from AppKit import NSControlStateValueOn, NSControlStateValueOff
            idx = sender.tag()
            if idx < 0 or idx >= len(LANGS):
                return
            lang = LANGS[idx]
            for lk, btn in self._primary_btns.items():
                btn.setState_(NSControlStateValueOn if lk == lang else NSControlStateValueOff)
            self._on_primary(lang)

        def additionalClicked_(self, sender):
            from AppKit import NSControlStateValueOn
            idx = sender.tag()
            if idx < 0 or idx >= len(LANGS):
                return
            lang = LANGS[idx]
            # NSButton (Switch type) auto-toggles before the action fires;
            # sender.state() already reflects the new state.
            self._on_additional(lang, sender.state() == NSControlStateValueOn)

    _HAVE_LANG_MENU = True

    class _PhraseMenuController(NSObject):
        """Phrase history NSMenu with NSMenuItem.setView_() items so the menu
        stays open when the user copies a phrase or taps '↓ Показать ещё'."""

        _VIEW_W = 280
        _ROW_H = 22
        _HEADER_H = 18
        _MARGIN = 14
        _MAX_TITLE = 46

        @_objc.python_method
        def configure(self) -> None:
            self._page_count: int = 5
            self._phrases: list = []
            self._ns_menu = None

        @_objc.python_method
        def build_ns_menu(self):
            from AppKit import NSMenu
            self._ns_menu = NSMenu.alloc().init()
            self._ns_menu.setAutoenablesItems_(False)
            self._do_rebuild()
            return self._ns_menu

        @_objc.python_method
        def rebuild(self) -> None:
            """Reset to page 1 and rebuild (called after a new phrase is saved)."""
            self._page_count = 5
            if self._ns_menu is not None:
                self._do_rebuild()

        @_objc.python_method
        def _do_rebuild(self) -> None:
            from AppKit import NSMenuItem

            count = self._page_count
            candidates = get_last_phrases(count + 1)
            has_more = len(candidates) > count
            phrases_oldest = candidates[-count:] if has_more else candidates
            self._phrases = list(reversed(phrases_oldest))

            self._ns_menu.removeAllItems()

            self._ns_menu.addItem_(self._header_item("Нажмите на фразу, чтобы скопировать"))
            self._ns_menu.addItem_(NSMenuItem.separatorItem())

            if not self._phrases:
                self._ns_menu.addItem_(self._header_item("Нет сохранённых фраз"))
                return

            for i, (_ts, text) in enumerate(self._phrases):
                title = (text[:self._MAX_TITLE - 1] + "…") if len(text) > self._MAX_TITLE else text
                self._ns_menu.addItem_(self._phrase_item(i, title))

            if has_more:
                self._ns_menu.addItem_(NSMenuItem.separatorItem())
                self._ns_menu.addItem_(self._load_more_item())

        @_objc.python_method
        def _header_item(self, text: str):
            from AppKit import NSMenuItem, NSTextField, NSFont
            view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, self._VIEW_W, self._HEADER_H))
            lbl = NSTextField.alloc().initWithFrame_(
                NSMakeRect(self._MARGIN, 2, self._VIEW_W - 2 * self._MARGIN, self._HEADER_H - 4)
            )
            lbl.setStringValue_(text)
            lbl.setBezeled_(False)
            lbl.setDrawsBackground_(False)
            lbl.setEditable_(False)
            lbl.setSelectable_(False)
            lbl.setFont_(NSFont.systemFontOfSize_(10))
            view.addSubview_(lbl)
            mi = NSMenuItem.alloc().init()
            mi.setView_(view)
            mi.setEnabled_(False)
            return mi

        @_objc.python_method
        def _phrase_item(self, index: int, display_title: str):
            from AppKit import (
                NSMenuItem, NSButton, NSButtonTypeMomentaryLight,
                NSTextAlignmentLeft, NSImage,
            )
            view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, self._VIEW_W, self._ROW_H))
            btn = NSButton.alloc().initWithFrame_(
                NSMakeRect(self._MARGIN, 1, self._VIEW_W - 2 * self._MARGIN, self._ROW_H - 2)
            )
            btn.setButtonType_(NSButtonTypeMomentaryLight)
            btn.setTitle_(display_title)
            btn.setBordered_(False)
            btn.setAlignment_(NSTextAlignmentLeft)
            btn.setTag_(index)
            btn.setTarget_(self)
            btn.setAction_("copyClicked:")
            icon_path = get_menu_item_icon_path("copy-phrase")
            if icon_path:
                img = NSImage.alloc().initWithContentsOfFile_(str(icon_path))
                if img:
                    img.setSize_((16, 16))
                    img.setTemplate_(True)
                    btn.setImage_(img)
                    btn.setImagePosition_(2)  # NSImageLeft
            view.addSubview_(btn)
            mi = NSMenuItem.alloc().init()
            mi.setView_(view)
            return mi

        @_objc.python_method
        def _load_more_item(self):
            from AppKit import NSMenuItem, NSButton, NSButtonTypeMomentaryLight, NSTextAlignmentCenter
            row_h = self._ROW_H + 6
            view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, self._VIEW_W, row_h))
            btn = NSButton.alloc().initWithFrame_(
                NSMakeRect(self._MARGIN, 3, self._VIEW_W - 2 * self._MARGIN, self._ROW_H)
            )
            btn.setButtonType_(NSButtonTypeMomentaryLight)
            btn.setTitle_("↓   Показать ещё")
            btn.setBordered_(True)
            btn.setAlignment_(NSTextAlignmentCenter)
            btn.setTarget_(self)
            btn.setAction_("loadMoreClicked:")
            view.addSubview_(btn)
            mi = NSMenuItem.alloc().init()
            mi.setView_(view)
            return mi

        def copyClicked_(self, sender) -> None:
            idx = int(sender.tag())
            if 0 <= idx < len(self._phrases):
                _ts, text = self._phrases[idx]
                copy_to_clipboard(text)
                self._show_copied_tooltip()
                # Close the menu after showing the tooltip; cancelTracking() is
                # safe to call from within a menu-tracking action callback.
                if self._ns_menu is not None:
                    self._ns_menu.cancelTracking()

        def loadMoreClicked_(self, sender) -> None:
            self._page_count += 5
            self._do_rebuild()

        @_objc.python_method
        def _show_copied_tooltip(self) -> None:
            from AppKit import (
                NSPanel, NSTextField, NSFont, NSColor, NSEvent,
                NSBackingStoreBuffered, NSFloatingWindowLevel, NSTextAlignmentCenter,
            )
            # Cancel any in-flight dismiss timer and close a previous tooltip that
            # is still visible (fast double-click within the 0.75s window).
            NSObject.cancelPreviousPerformRequestsWithTarget_selector_object_(
                self, "_dismissCopiedPanel:", None
            )
            if getattr(self, "_copied_panel", None) is not None:
                self._copied_panel.close()
                self._copied_panel = None
            mouse = NSEvent.mouseLocation()
            W, H = 84, 26
            panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
                NSMakeRect(mouse.x - W / 2, mouse.y + 14, W, H),
                0,  # NSWindowStyleMaskBorderless
                NSBackingStoreBuffered,
                False,
            )
            panel.setLevel_(NSFloatingWindowLevel)
            panel.setOpaque_(False)
            panel.setBackgroundColor_(
                NSColor.colorWithCalibratedRed_green_blue_alpha_(0.12, 0.12, 0.12, 0.86)
            )
            panel.setHasShadow_(True)
            lbl = NSTextField.alloc().initWithFrame_(NSMakeRect(0, 3, W, H - 4))
            lbl.setStringValue_("Copied")
            lbl.setBezeled_(False)
            lbl.setDrawsBackground_(False)
            lbl.setEditable_(False)
            lbl.setSelectable_(False)
            lbl.setAlignment_(NSTextAlignmentCenter)
            lbl.setTextColor_(NSColor.whiteColor())
            lbl.setFont_(NSFont.boldSystemFontOfSize_(12))
            panel.contentView().addSubview_(lbl)
            panel.orderFront_(None)
            self._copied_panel = panel
            self.performSelector_withObject_afterDelay_("_dismissCopiedPanel:", None, 0.75)

        def _dismissCopiedPanel_(self, _) -> None:
            if getattr(self, "_copied_panel", None) is not None:
                self._copied_panel.close()
                self._copied_panel = None

    _HAVE_PHRASE_MENU = True

except Exception as _lang_menu_exc:
    import logging as _logging
    _logging.getLogger(__name__).error("Language submenu unavailable: %s", _lang_menu_exc)
    _LangMenuController = None  # type: ignore
    _HAVE_LANG_MENU = False
    _PhraseMenuController = None  # type: ignore
    _HAVE_PHRASE_MENU = False


try:
    from AppKit import NSObject as _NSObject  # type: ignore

    class _MainMenuDelegate(_NSObject):
        """NSMenuDelegate: refreshes permission indicators when the menu opens."""
        _owner = None

        def menuWillOpen_(self, menu) -> None:
            if self._owner is not None:
                self._owner._refresh_permissions()

    _HAVE_MENU_DELEGATE = True
except Exception:
    _MainMenuDelegate = None  # type: ignore
    _HAVE_MENU_DELEGATE = False


def _prompt_restart(reason: str) -> None:
    """Show a modal asking the user to relaunch the app. Relaunches on OK."""
    try:
        from AppKit import NSAlert  # type: ignore
        alert = NSAlert.alloc().init()
        alert.setAlertStyle_(1)
        alert.setMessageText_("Restart Click-n-speak")
        alert.setInformativeText_(
            f"{reason}\n\nClick-n-speak needs to restart to activate the global "
            f"hotkey (Alt+Space).\n\nRestart now?"
        )
        alert.addButtonWithTitle_("Restart Now")
        alert.addButtonWithTitle_("Later")
        clicked = alert.runModal() - 1000
        if clicked == 0:
            log_info("User accepted restart prompt — relaunching app.")
            relaunch_app()
    except Exception as exc:
        log_error(f"Restart prompt failed: {exc}")


class ClickNSpeakApp(rumps.App):
    def __init__(self, main_app):
        icon_path = str(get_menu_icon_path())
        super(ClickNSpeakApp, self).__init__("", icon=icon_path)
        self.template = True  # render menubar icon as template (adapts to dark/light mode)
        self.main_app = main_app
        self.config = main_app.config
        self._prompt_mtimes: dict = {}  # {lang: last_observed_mtime}
        self._accessibility_granted = is_accessibility_trusted()
        self._accessibility_item = None  # set in setup_menu
        self._input_monitoring_ok: bool | None = None  # None = unknown until health check
        self._input_monitoring_item = None  # set in setup_menu
        self._microphone_ok: bool | None = None  # None = unknown until first check
        self._microphone_item = None  # set in setup_menu
        self._permissions_item = None  # parent Permissions menu item
        self._wizard_pending = False
        self._suggestion_check_done: bool = False
        self._lang_menu_controller: "_LangMenuController | None" = None
        self._phrase_menu_controller: "_PhraseMenuController | None" = None
        self._phrases_page_count: int = 5  # used only in the rumps fallback path
        self._mode_items: dict = {}

        try:
            from .suggestions_panel import SuggestionsPanel
            self._suggestions_panel: "SuggestionsPanel | None" = SuggestionsPanel()
        except Exception as exc:
            log_error(f"SuggestionsPanel unavailable: {exc}")
            self._suggestions_panel = None

        # Build Menu
        self.setup_menu()

        # Hook tap-failure callback after menu is built so _input_monitoring_item exists
        self.main_app.hotkey_handler.on_tap_failed = self._on_tap_failed
        # Asynchronously check which Whisper models are already cached
        self._start_model_cache_check()

    def _get_prompt_path(self, lang: str = None):
        """Returns the absolute path to initial_prompt_{lang}.txt."""
        if not lang:
            lang = get_primary_language(self.config)
        return get_config_path().parent / f"initial_prompt_{lang}.txt"

    @rumps.timer(0.3)
    def _drain_main_thread_queue(self, _):
        """Drain logic app's main-thread job queue so UI updates run on the main thread."""
        app = self.main_app
        if not hasattr(app, "_main_thread_queue"):
            return
        while True:
            try:
                job = app._main_thread_queue.get_nowait()
            except queue.Empty:
                break
            fn, args, kwargs = job
            try:
                fn(*args, **kwargs)
            except Exception as e:
                log_error(f"Main thread job failed: {e}")

    @rumps.timer(1.0)
    def _watch_prompt_file(self, _):
        """Watches initial_prompt_{lang}.txt for all active languages; updates user_terms on change."""
        primary = get_primary_language(self.config)
        additional = list(self.config.get("additional_languages") or [])
        all_langs = [primary] + [l for l in additional if l != primary]

        for lang in all_langs:
            prompt_path = self._get_prompt_path(lang)
            if not prompt_path.exists():
                continue
            try:
                mtime = prompt_path.stat().st_mtime
                if self._prompt_mtimes.get(lang, 0.0) == 0.0:
                    self._prompt_mtimes[lang] = mtime
                    continue

                if mtime > self._prompt_mtimes[lang]:
                    self._prompt_mtimes[lang] = mtime
                    with prompt_path.open("r", encoding="utf-8") as f:
                        new_text = f.read().strip()

                    user_terms = dict(self.config.get("user_terms") or {})
                    previous_terms = list(user_terms.get(lang, []))
                    new_terms = deduplicate_prompt_terms(parse_prompt_terms(new_text))

                    if previous_terms != new_terms:
                        if previous_terms:
                            snapshots = dict(self.config.get("prompt_snapshots", {}))
                            snapshots[lang] = previous_terms
                            self.config["prompt_snapshots"] = snapshots

                        user_terms[lang] = new_terms
                        self.config["user_terms"] = user_terms
                        self.config["initial_prompt"] = build_initial_prompt(self.config)

                        self.save_config()
                        self.main_app.load_config_data(self.config)
                        log_info(f"Initial prompt updated manually for {lang.upper()}.")
                        self.main_app.notify("Настройки", f"Подсказка для {lang.upper()} обновлена!")
            except Exception as e:
                log_error(f"Error checking prompt file for {lang}: {e}")

    # ------------------------------------------------------------------
    # Setup wizard
    # ------------------------------------------------------------------

    def schedule_setup_wizard(self) -> None:
        """Schedule the permission wizard to run after 1 s (once the menu bar is visible)."""
        self._wizard_pending = True
        log_info("Setup wizard scheduled.")

    @rumps.timer(1.0)
    def _run_wizard_if_pending(self, _) -> None:
        """One-shot timer: runs the setup wizard and checks Input Monitoring on first tick."""
        # Check Input Monitoring and Microphone once after NSApp has started
        if self._input_monitoring_ok is None:
            self._input_monitoring_ok = check_input_monitoring()
            self._update_input_monitoring_item()
            if not self._input_monitoring_ok:
                log_error(
                    "Input Monitoring permission not granted — hotkeys will not work. "
                    "Add Click-n-speak to Privacy & Security → Input Monitoring."
                )
        if self._microphone_ok is None:
            self._microphone_ok = check_microphone() == "granted"
            self._update_microphone_item()

        if self._wizard_pending:
            self._wizard_pending = False
            try:
                from .setup_wizard import run_setup_wizard
                run_setup_wizard()
                self._accessibility_granted = is_accessibility_trusted()
                self._update_accessibility_menu_item()
                self._microphone_ok = check_microphone() == "granted"
                self._update_microphone_item()
            except Exception as exc:
                log_error(f"Setup wizard error: {exc}")

        if not self._suggestion_check_done:
            self._suggestion_check_done = True
            try:
                self._check_pending_suggestions_on_startup()
            except Exception as exc:
                log_error(f"Suggestions startup check failed: {exc}")

    def _update_microphone_item(self) -> None:
        if self._microphone_item is None:
            return
        if self._microphone_ok:
            self._microphone_item.title = "Microphone — Granted"
            p = get_menu_item_icon_path("microphone-ok")
        else:
            self._microphone_item.title = "Microphone — Required"
            p = get_menu_item_icon_path("microphone-warn")
        if p:
            self._microphone_item.set_icon(str(p), dimensions=[16, 16], template=False)
        self._update_permissions_parent_item()

    def _on_microphone_click(self, _) -> None:
        if not self._microphone_ok:
            open_microphone_settings()
        else:
            self.main_app.notify("Доступ", "Доступ к микрофону уже предоставлен.")

    def _refresh_permissions(self) -> None:
        """Refresh all permission indicators. Called at startup and on menu open."""
        from .setup_wizard import is_wizard_active
        try:
            trusted = is_accessibility_trusted()
            if trusted != self._accessibility_granted:
                self._accessibility_granted = trusted
                self._update_accessibility_menu_item()

            im_ok = check_input_monitoring()
            if im_ok != self._input_monitoring_ok:
                self._input_monitoring_ok = im_ok
                self._update_input_monitoring_item()

            mic_ok = check_microphone() == "granted"
            if mic_ok != self._microphone_ok:
                self._microphone_ok = mic_ok
                self._update_microphone_item()

            # If all permissions are now granted but the listener isn't running,
            # the user must restart. Prompt once (wizard handles its own prompt).
            # Deferred via performSelector so any open NSMenu finishes closing first.
            if (
                trusted
                and self._input_monitoring_ok
                and not self.main_app.hotkey_handler.is_listener_alive()
                and not is_wizard_active()
                and not getattr(self, "_restart_prompt_shown", False)
            ):
                self._restart_prompt_shown = True
                # Defer past the current NSMenu close cycle; _main_thread_queue
                # drains on the next 0.3s tick, after the menu is gone.
                self._submit_for_main_thread(
                    lambda: _prompt_restart("All required permissions are now granted.")
                )
        except Exception as e:
            log_error(f"Error refreshing permissions: {e}")

    def _update_accessibility_menu_item(self) -> None:
        if self._accessibility_item is None:
            return
        if self._accessibility_granted:
            self._accessibility_item.title = "Accessibility — Granted"
            p = get_menu_item_icon_path("accessibility-ok")
        else:
            self._accessibility_item.title = "Accessibility — Required"
            p = get_menu_item_icon_path("accessibility-warn")
        if p:
            self._accessibility_item.set_icon(str(p), dimensions=[16, 16], template=False)
        self._update_permissions_parent_item()

    def _on_accessibility_click(self, _) -> None:
        if not self._accessibility_granted:
            open_accessibility_settings()
        else:
            self.main_app.notify("Доступ", "Права доступа уже предоставлены.")

    # ------------------------------------------------------------------
    # Input Monitoring (macOS 15+ — separate from Accessibility)
    # ------------------------------------------------------------------

    def _on_tap_failed(self) -> None:
        """Called from hotkey health-check thread when CGEventTap creation failed."""
        self._input_monitoring_ok = False
        self.main_app._submit_for_main_thread(self._show_input_monitoring_required)

    def _show_input_monitoring_required(self) -> None:
        from .setup_wizard import is_wizard_active
        self._update_input_monitoring_item()
        if not is_wizard_active():
            send_notification(
                "Click-n-speak — Hotkeys Disabled",
                "Add Click-n-speak to Privacy & Security → Input Monitoring to enable hotkeys.",
            )

    def _update_input_monitoring_item(self) -> None:
        if self._input_monitoring_item is None:
            return
        if self._input_monitoring_ok is None:
            self._input_monitoring_item.title = "Input Monitoring — Checking…"
            p = get_menu_item_icon_path("input-monitoring-warn")
        elif self._input_monitoring_ok:
            self._input_monitoring_item.title = "Input Monitoring — Granted"
            p = get_menu_item_icon_path("input-monitoring-ok")
        else:
            self._input_monitoring_item.title = "Input Monitoring — Required"
            p = get_menu_item_icon_path("input-monitoring-warn")
        if p:
            self._input_monitoring_item.set_icon(str(p), dimensions=[16, 16], template=False)
        self._update_permissions_parent_item()

    def _update_permissions_parent_item(self) -> None:
        if self._permissions_item is None:
            return
        all_ok = (
            self._accessibility_granted
            and bool(self._input_monitoring_ok)
            and bool(self._microphone_ok)
        )
        p = get_menu_item_icon_path("permissions-ok" if all_ok else "permissions-warn")
        if p:
            self._permissions_item.set_icon(str(p), dimensions=[16, 16], template=False)

    def _on_input_monitoring_click(self, _) -> None:
        if not self._input_monitoring_ok:
            open_input_monitoring_settings()
        else:
            self.main_app.notify("Доступ", "Input Monitoring уже разрешён.")

    def setup_menu(self):
        def _icon(name: str) -> dict:
            p = get_menu_item_icon_path(name)
            return {"icon": str(p), "dimensions": [16, 16], "template": True} if p else {}

        # Permissions parent item with submenu
        self._permissions_item = rumps.MenuItem("Permissions")
        self._microphone_item = rumps.MenuItem("", callback=self._on_microphone_click)
        self._update_microphone_item()
        self._permissions_item.add(self._microphone_item)
        self._accessibility_item = rumps.MenuItem("", callback=self._on_accessibility_click)
        self._update_accessibility_menu_item()
        self._permissions_item.add(self._accessibility_item)
        self._input_monitoring_item = rumps.MenuItem("", callback=self._on_input_monitoring_click)
        self._update_input_monitoring_item()
        self._permissions_item.add(self._input_monitoring_item)
        self._update_permissions_parent_item()
        self.menu.add(self._permissions_item)
        self.menu.add(None)  # Separator

        # Model selection submenu
        current_model = self.config.get("model_name", "mlx-community/whisper-large-v3-turbo")
        self.menu.add(rumps.MenuItem("Model", **_icon("model")))
        _dl_icon = get_menu_item_icon_path("download-model")
        for label, model_id in WHISPER_MODELS:
            item = rumps.MenuItem(label, callback=self.change_model)
            if _dl_icon:
                item.set_icon(str(_dl_icon), dimensions=[16, 16], template=True)
            if model_id == current_model:
                item.state = 1
            self.menu["Model"].add(item)

        # Language selection — native submenu, stays open after clicks via NSMenuItem.setView_()
        lang_item = rumps.MenuItem("Languages", **_icon("languages"))
        self.menu.add(lang_item)
        if _HAVE_LANG_MENU:
            try:
                self._lang_menu_controller = _LangMenuController.alloc().init()
                self._lang_menu_controller.configure(
                    self.config,
                    self._apply_primary_language,
                    self._apply_additional_language,
                )
                ns_submenu = self._lang_menu_controller.build_submenu()
                lang_item._menuitem.setSubmenu_(ns_submenu)
            except Exception as exc:
                log_error(f"Language submenu build failed: {exc}")

        self.menu.add(None)  # Separator

        # AI Editor toggle
        ai_editor_item = rumps.MenuItem("AI Editor (Punctuation & Cleanup)", **_icon("ai-editor"), callback=self._toggle_ai_editor)
        ai_editor_item.state = 1 if self.config.get("ai_editor_enabled", False) else 0
        self.menu.add(ai_editor_item)

        # AI Editor Backend submenu
        self._ai_backend_submenu = rumps.MenuItem("AI Editor Backend ▶")
        self._ai_backend_local_item = rumps.MenuItem("Local (Qwen)", callback=self._on_set_ai_backend_local)
        self._ai_backend_gemini_item = rumps.MenuItem("Gemini API", callback=self._on_set_ai_backend_gemini)
        self._ai_backend_submenu.add(self._ai_backend_local_item)
        self._ai_backend_submenu.add(self._ai_backend_gemini_item)
        self.menu.add(self._ai_backend_submenu)
        self._update_ai_backend_submenu_state()

        self.menu.add(rumps.MenuItem("Download AI Editor Model", **_icon("download-model"), callback=self._download_ai_model))

        # Initial Prompt submenu
        self._prompt_menu_item = rumps.MenuItem("Initial Prompt", **_icon("initial-prompt"))
        self._prompt_menu_item.add(rumps.MenuItem("Edit Initial Prompt", callback=self.edit_initial_prompt))
        self._prompt_menu_item.add(rumps.MenuItem("Revert Initial Prompt", callback=self.revert_initial_prompt))
        self._prompt_menu_item.add(None)

        # Auto-update Mode submenu (Suggest / Auto / Disabled)
        self._mode_items = {}
        mode_menu = rumps.MenuItem("Auto-update Mode")
        for _mode_key, _mode_label in [
            ("suggest", "Suggest (по умолчанию)"),
            ("auto", "Auto"),
            ("disabled", "Disabled"),
        ]:
            _item = rumps.MenuItem(
                _mode_label,
                callback=lambda _, m=_mode_key: self._on_set_update_mode(m),
            )
            self._mode_items[_mode_key] = _item
            mode_menu.add(_item)
        self._prompt_menu_item.add(mode_menu)
        self._update_mode_submenu_state()

        self._prompt_menu_item.add(None)

        self._suggest_item = rumps.MenuItem("Review Suggestions", callback=self._on_review_suggestions)
        self._prompt_menu_item.add(self._suggest_item)
        self.menu.add(self._prompt_menu_item)
        self.update_suggest_menu_badge()

        # Phrase history
        self._last_phrases_parent = rumps.MenuItem("Last Phrases", **_icon("last-phrases"))
        self.menu.add(self._last_phrases_parent)
        if _HAVE_PHRASE_MENU:
            try:
                self._phrase_menu_controller = _PhraseMenuController.alloc().init()
                self._phrase_menu_controller.configure()
                ns_submenu = self._phrase_menu_controller.build_ns_menu()
                self._last_phrases_parent._menuitem.setSubmenu_(ns_submenu)
            except Exception as exc:
                log_error(f"Phrase history submenu build failed: {exc}")
                self._phrase_menu_controller = None
                self._refresh_last_phrases_submenu()
        else:
            self._refresh_last_phrases_submenu()

        self.menu.add(rumps.MenuItem("Transcribe Audio File...", **_icon("transcribe-file"), callback=self.transcribe_audio_file))

        self.menu.add(None)  # Separator

        self.menu.add(rumps.MenuItem("Check for Updates", **_icon("check-updates"), callback=self.check_for_updates))

        # Autostart
        autostart_item = rumps.MenuItem("Launch at Login", **_icon("launch-at-login"), callback=self.toggle_autostart)
        autostart_item.state = 1 if is_launch_at_login_enabled() else 0
        self.menu.add(autostart_item)

        # Advanced submenu
        advanced_menu = rumps.MenuItem("Advanced", **_icon("advanced"))
        advanced_menu.add(rumps.MenuItem("Edit Config File", callback=self.open_config))
        advanced_menu.add(rumps.MenuItem("Open Log File", callback=self.open_log_file))
        advanced_menu.add(rumps.MenuItem("Reload Configuration", callback=self.reload_config))
        self.menu.add(advanced_menu)

        self.menu.add(rumps.MenuItem("Restart", **_icon("restart"), callback=self.restart_application))
        self.menu.add(None)

        # Apply the idle icon on startup (overrides CnS.png set in __init__)
        self.set_menubar_state("idle")

        # Refresh permissions on menu open via NSMenuDelegate
        if _HAVE_MENU_DELEGATE:
            try:
                self._menu_delegate = _MainMenuDelegate.alloc().init()
                self._menu_delegate._owner = self
                self.menu._menu.setDelegate_(self._menu_delegate)
            except Exception as exc:
                log_error(f"Could not install menu delegate: {exc}")

    # ------------------------------------------------------------------
    # Whisper model cache check
    # ------------------------------------------------------------------

    def _start_model_cache_check(self) -> None:
        """Start a daemon thread that checks HuggingFace cache for all Whisper models."""
        t = threading.Thread(target=self._update_model_cache_indicators, daemon=True)
        t.start()

    def _update_model_cache_indicators(self) -> None:
        """Check each Whisper model against the local HF cache and update menu icons.

        Runs in a background thread; schedules UI updates on the main thread.
        """
        try:
            from huggingface_hub import snapshot_download  # type: ignore
        except ImportError:
            log_error("huggingface_hub not installed — cannot check model cache status.")
            return

        for label, model_id in WHISPER_MODELS:
            try:
                snapshot_download(repo_id=model_id, local_files_only=True)
                cached = True
            except Exception:
                cached = False

            def _apply(lbl: str = label, is_cached: bool = cached) -> None:
                try:
                    for item in self.menu["Model"].values():
                        # Strip 🟢 prefix to find the base label
                        base = item.title
                        if base.startswith(_ICON_CACHED):
                            base = base[len(_ICON_CACHED):].lstrip()
                        if base == lbl:
                            if is_cached:
                                item.title = f"{_ICON_CACHED} {lbl}"
                                item.set_icon(None)
                            else:
                                item.title = lbl
                                p = get_menu_item_icon_path("download-model")
                                if p:
                                    item.set_icon(str(p), dimensions=[16, 16], template=True)
                            break
                except Exception as exc:
                    log_error(f"Model cache indicator update failed for '{lbl}': {exc}")

            # Post to main-thread queue so rumps UI stays thread-safe
            if hasattr(self.main_app, "_main_thread_queue"):
                self.main_app._main_thread_queue.put((_apply, [], {}))
            else:
                _apply()

    def change_model(self, sender):
        # Strip 🟢 prefix if present (e.g. "🟢 Turbo" → "Turbo")
        clean_label = sender.title
        if clean_label.startswith(_ICON_CACHED):
            clean_label = clean_label[len(_ICON_CACHED):].lstrip()

        model_id = {lbl: mid for lbl, mid in WHISPER_MODELS}.get(clean_label)
        if not model_id:
            log_error(f"change_model: unknown label '{clean_label}'")
            return

        log_info(f"Switching model to {model_id}")
        self.main_app.update_config({"model_name": model_id})

        # Update UI: uncheck all, then check the selected item
        for item in self.menu["Model"].values():
            if hasattr(item, "state"):
                item.state = 0  # type: ignore
        sender.state = 1

    def _apply_primary_language(self, lang: str) -> None:
        """Apply a primary language change (called from the language panel)."""
        log_info(f"Setting primary language to {lang}")
        self.config["primary_language"] = lang
        self._update_language_hint_and_prompt()
        # update_config saves to disk and calls load_config_data internally —
        # pass the full config so custom_prompts/initial_prompt are persisted too.
        self.main_app.update_config(self.config)
        self._prompt_mtimes.clear()

    def _apply_additional_language(self, lang: str, is_on: bool) -> None:
        """Toggle an additional language (called from the language panel)."""
        additional = list(self.config.get("additional_languages") or [])
        if not additional and isinstance(self.config.get("languages"), list) and len(self.config["languages"]) > 1:
            additional = [str(x).lower().strip() for x in self.config["languages"][1:] if x]
        if is_on and lang not in additional:
            additional.append(lang)
        elif not is_on and lang in additional:
            additional.remove(lang)
        self.config["additional_languages"] = additional
        self._update_language_hint_and_prompt()
        log_info(f"Additional languages: {additional}")
        self.main_app.update_config(self.config)

    def _update_language_hint_and_prompt(self):
        """Rebuild initial_prompt after a language change.

        Ensures user_terms[primary] exists (creates empty list if needed) so the
        prompt file and menu always have a valid entry for the active language.
        Language hints are embedded by build_initial_prompt automatically.
        """
        primary = get_primary_language(self.config)
        user_terms = dict(self.config.get("user_terms") or {})
        user_terms.setdefault(primary, [])
        self.config["user_terms"] = user_terms

        self.config["initial_prompt"] = build_initial_prompt(self.config)

        # Sync the .txt file so "Edit..." shows the current state.
        try:
            terms_list = user_terms.get(primary, [])
            prompt_path = self._get_prompt_path(primary)
            with prompt_path.open("w", encoding="utf-8") as f:
                f.write(", ".join(terms_list))
        except Exception as e:
            log_error(f"Failed to write prompt file for {primary}: {e}")

    def _refresh_last_phrases_submenu(self) -> None:
        """Rebuild the phrase history submenu (rumps fallback only — native path uses _PhraseMenuController)."""
        if getattr(self, "_phrase_menu_controller", None) is not None:
            return
        parent = self._last_phrases_parent
        for key in list(parent.keys()):
            del parent[key]

        count = self._phrases_page_count
        # Request one extra to detect if more exist — avoids a second file read.
        candidates = get_last_phrases(count + 1)
        has_more = len(candidates) > count
        phrases = candidates[-count:] if has_more else candidates

        # Hint header (non-clickable, shown grayed out by macOS)
        parent.add(rumps.MenuItem("Нажмите на фразу, чтобы скопировать", callback=None))
        parent.add(None)

        if not phrases:
            parent.add(rumps.MenuItem("Нет сохранённых фраз", callback=None))
            return

        max_title_len = 56
        copy_icon = get_menu_item_icon_path("copy-phrase")
        copy_icon_kwargs = {"icon": str(copy_icon), "dimensions": [16, 16], "template": True} if copy_icon else {}
        for i, (_ts, text) in enumerate(reversed(phrases)):
            title = (text[: max_title_len - 1] + "…") if len(text) > max_title_len else text
            if not title:
                title = "(empty)"
            # Append zero-width spaces so identical display titles remain unique rumps keys,
            # preventing NSMenuItem leaks when the same phrase appears multiple times.
            unique_title = title + "​" * i
            parent.add(
                rumps.MenuItem(unique_title, **copy_icon_kwargs, callback=lambda s, t=text: copy_to_clipboard(t))
            )

        if has_more:
            parent.add(None)
            parent.add(rumps.MenuItem("↓  Показать ещё", callback=self._show_more_phrases))

    def _show_more_phrases(self, _) -> None:
        """Load the next 5 phrases and rebuild the submenu."""
        self._phrases_page_count += 5
        self._refresh_last_phrases_submenu()

    def refresh_last_phrases_submenu(self) -> None:
        """Public method — resets to the first page and rebuilds (called after a new phrase is saved)."""
        if getattr(self, "_phrase_menu_controller", None) is not None:
            self._phrase_menu_controller.rebuild()
            return
        self._phrases_page_count = 5
        self._refresh_last_phrases_submenu()

    def open_config(self, _: rumps.MenuItem) -> None:
        """Opens config.json in the default editor (no shell)."""
        subprocess.run(["open", str(get_config_path())], check=False)

    def open_log_file(self, _: rumps.MenuItem) -> None:
        """Opens the app log file in the default editor (all recognition requests are logged there)."""
        log_path = get_log_file_path()
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.touch(exist_ok=True)  # create if user deleted it
        except OSError:
            pass
        subprocess.run(["open", str(log_path)], check=False)

    def reload_config(self, _: rumps.MenuItem) -> None:
        """Reloads config from disk and refreshes the menu."""
        self.main_app.load_config(str(get_config_path()))
        self.config = self.main_app.config  # sync reference in case load replaced the dict
        self.main_app.notify("Конфигурация", "Настройки успешно перезагружены.")
        self._lang_menu_controller = None  # will be rebuilt in setup_menu()
        self.menu.clear()
        self.setup_menu()

    def edit_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Open primary-language user_terms in a text editor."""
        self._edit_prompt_for_lang(get_primary_language(self.config))

    def _edit_prompt_for_lang(self, lang: str) -> None:
        """Write user_terms[lang] to its .txt file and open it in the default editor."""
        self._sync_prompt_file(lang)
        prompt_path = str(self._get_prompt_path(lang))
        try:
            subprocess.run(["open", "-t", prompt_path], check=False)
            # Raise the editor's window to front. Needed when the editor was already
            # running: the new document window can open behind existing ones.
            # AXRaise is called after a short delay to let the editor finish loading.
            applescript = (
                "delay 0.8\n"
                "tell application \"System Events\"\n"
                "    set theProc to first process where frontmost is true\n"
                "    set frontmost of theProc to true\n"
                "    if (count of windows of theProc) > 0 then\n"
                "        perform action \"AXRaise\" of window 1 of theProc\n"
                "    end if\n"
                "end tell"
            )
            subprocess.Popen(["osascript", "-e", applescript])
        except OSError as e:
            log_error(f"Failed to open initial prompt for {lang}: {e}")

    def _sync_prompt_file(self, lang: str) -> None:
        """Write current user_terms[lang] to its .txt file and update the mtime tracker."""
        user_terms = self.config.get("user_terms") or {}
        terms_list = list(user_terms.get(lang, []))
        prompt_path = self._get_prompt_path(lang)
        try:
            with prompt_path.open("w", encoding="utf-8") as f:
                f.write(", ".join(terms_list))
            self._prompt_mtimes[lang] = prompt_path.stat().st_mtime
        except OSError as exc:
            log_error(f"Failed to sync prompt file for {lang}: {exc}")

    def revert_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Swap primary-language user_terms with prompt_snapshots (one-step undo)."""
        self._revert_for_lang(get_primary_language(self.config))

    def _revert_for_lang(self, lang: str) -> None:
        """Swap user_terms[lang] with prompt_snapshots[lang] (one-step undo)."""
        snapshots = dict(self.config.get("prompt_snapshots", {}))
        prev_terms = snapshots.get(lang)

        if not prev_terms:
            self.main_app.notify("Настройки", f"Нет предыдущей версии подсказки для {lang.upper()}.")
            return

        user_terms = dict(self.config.get("user_terms") or {})
        current_terms = list(user_terms.get(lang, []))

        user_terms[lang] = list(prev_terms)
        snapshots[lang] = current_terms

        self.config["user_terms"] = user_terms
        self.config["prompt_snapshots"] = snapshots
        self.config["initial_prompt"] = build_initial_prompt(self.config)

        prompt_path = self._get_prompt_path(lang)
        try:
            with prompt_path.open("w", encoding="utf-8") as f:
                f.write(", ".join(prev_terms))
            self._prompt_mtimes[lang] = prompt_path.stat().st_mtime
        except Exception:
            pass

        self.save_config()
        self.main_app.load_config_data(self.config)
        self.main_app.notify("Настройки", f"Подсказка для {lang.upper()} восстановлена.")

    def _update_mode_submenu_state(self) -> None:
        """Sync Auto-update Mode checkmarks with current prompt_update_mode."""
        current = self.config.get("prompt_update_mode", "suggest")
        for mode_key, item in self._mode_items.items():
            item.state = 1 if mode_key == current else 0

    def _on_set_update_mode(self, mode: str) -> None:
        """Change prompt_update_mode and reflect in menu checkmarks."""
        self.config["prompt_update_mode"] = mode
        self._update_mode_submenu_state()
        self.save_config()
        self.main_app.load_config_data(self.config)
        labels = {"suggest": "Suggest", "auto": "Auto", "disabled": "Disabled"}
        self.main_app.notify("Настройки", f"Режим авто-обновления: {labels.get(mode, mode)}")

    def transcribe_audio_file(self, _: rumps.MenuItem) -> None:
        """Opens a file selection dialog and starts file transcription."""
        if self.main_app.is_recording or self.main_app.is_processing:
            self.main_app.notify("Занято", "Пожалуйста, дождитесь окончания текущего распознавания.")
            return

        try:
            # osascript dialog to pick a file
            script = 'set theFile to choose file with prompt "Select Audio File" of type {"public.audio", "wav", "m4a"} \n POSIX path of theFile'
            result = subprocess.check_output(['osascript', '-e', script])
            file_path = result.decode('utf-8').strip()
            
            if file_path and os.path.exists(file_path):
                self.main_app.start_file_transcription(file_path)
            
        except subprocess.CalledProcessError:
            # User canceled the dialog
            pass
        except Exception as e:
            log_error(f"Error selecting audio file: {e}")
            self.main_app.notify("Ошибка", "Не удалось открыть выбор файла.")

    # ------------------------------------------------------------------
    # Vocabulary suggestions
    # ------------------------------------------------------------------

    def update_suggest_menu_badge(self) -> None:
        """Update 'Review Suggestions' item title based on pending count."""
        try:
            pending = self.config.get("pending_suggestions") or {}
            total = sum(len(v) for v in pending.values())
            if total > 0:
                self._suggest_item.title = f"● Review Suggestions ({total})"
            else:
                self._suggest_item.title = "Review Suggestions"
        except Exception as exc:
            log_error(f"update_suggest_menu_badge failed: {exc}")

    def _check_pending_suggestions_on_startup(self) -> None:
        """Show startup alert if there are pending suggestions and mode is 'suggest'."""
        pending = self.config.get("pending_suggestions") or {}
        total = sum(len(v) for v in pending.values())
        if total == 0:
            return
        if self.config.get("prompt_update_mode", "suggest") != "suggest":
            return
        self._show_suggestions_alert(total, pending)

    def _show_suggestions_alert(self, total: int, pending: dict) -> None:
        """Show blocking NSAlert with 3 choices for handling pending suggestions."""
        try:
            from AppKit import NSAlert

            all_items: list[dict] = []
            for items in pending.values():
                all_items.extend(items)
            all_items.sort(key=lambda x: -x["count"])
            preview_parts = [f"{i['term']} ({i['count']}×)" for i in all_items[:3]]
            preview = ", ".join(preview_parts)
            if total > 3:
                preview += f"  и ещё {total - 3}"

            alert = NSAlert.alloc().init()
            alert.setMessageText_("Новые термины для словаря")
            alert.setInformativeText_(
                f"Найдено {total} терминов, часто встречающихся в ваших диктовках.\n"
                f"{preview}\n\n"
                "Добавление их повысит точность распознавания Whisper."
            )
            alert.addButtonWithTitle_("Посмотреть список")
            alert.addButtonWithTitle_("Напомнить позже")
            alert.addButtonWithTitle_("Добавлять автоматически")

            result = alert.runModal()  # 1000=first, 1001=second, 1002=third
            if result == 1000:
                self._open_suggestions_panel()
            elif result == 1002:
                self._apply_all_pending_suggestions()
                self.config["prompt_update_mode"] = "auto"
                self._update_mode_submenu_state()
                self.save_config()
                self.main_app.load_config_data(self.config)
                self.update_suggest_menu_badge()
            # 1001 = "Напомнить позже" — pending stays, shown again next startup.
        except Exception as exc:
            log_error(f"Suggestions alert failed: {exc}")

    def _on_review_suggestions(self, _) -> None:
        """Menu item callback: open the review panel, running on-demand analysis if needed."""
        pending = self.config.get("pending_suggestions") or {}
        total = sum(len(v) for v in pending.values())
        if total > 0:
            self._open_suggestions_panel()
            return

        try:
            from .phrase_history import count_phrases
            phrase_count = count_phrases()
        except Exception:
            phrase_count = 0

        if phrase_count < 5:
            self.main_app.notify(
                "Настройки",
                "История диктовок пока слишком мала. Запишите несколько диктовок и попробуйте снова.",
            )
            return

        self.main_app.notify("Настройки", "Анализирую историю диктовок…")
        self.main_app.request_prompt_analysis(on_complete=self._on_demand_analysis_done)

    def _on_demand_analysis_done(self) -> None:
        """Called on main thread after an on-demand analysis completes."""
        self.update_suggest_menu_badge()
        pending = self.config.get("pending_suggestions") or {}
        total = sum(len(v) for v in pending.values())
        if total > 0:
            self._open_suggestions_panel()
        else:
            self.main_app.notify(
                "Настройки",
                "В истории не найдено терминов, достаточно часто повторяющихся для добавления в словарь.",
            )

    def _open_suggestions_panel(self) -> None:
        """Open the SuggestionsPanel for reviewing candidates."""
        if self._suggestions_panel is None:
            return
        pending = self.config.get("pending_suggestions") or {}
        if not pending:
            return

        def on_accept(accepted: list[dict], rejected: list[dict]) -> None:
            from .app import _apply_candidates_to_user_terms
            if accepted:
                by_lang: dict[str, list[dict]] = {}
                for item in accepted:
                    by_lang.setdefault(item["lang"], []).append(item)
                _apply_candidates_to_user_terms(self.config, by_lang)
                for lang in by_lang:
                    self._sync_prompt_file(lang)

            # Rejected → skipped_terms with current phrase count
            if rejected:
                from .phrase_history import count_phrases
                current_count = count_phrases()
                skipped_terms = dict(self.config.get("skipped_terms") or {})
                for item in rejected:
                    lang = item["lang"]
                    lang_skipped = dict(skipped_terms.get(lang, {}))
                    lang_skipped[item["term"].lower()] = current_count
                    skipped_terms[lang] = lang_skipped
                self.config["skipped_terms"] = skipped_terms

            # Remove shown items from pending (items not yet shown remain pending).
            shown_lower = {i["term"].lower() for i in accepted + rejected}
            new_pending: dict[str, list[dict]] = {}
            for lang, items in pending.items():
                remaining = [i for i in items if i["term"].lower() not in shown_lower]
                if remaining:
                    new_pending[lang] = remaining
            self.config["pending_suggestions"] = new_pending
            self.config["initial_prompt"] = build_initial_prompt(self.config)
            self.save_config()
            self.main_app.load_config_data(self.config)
            self.update_suggest_menu_badge()

        def on_skip() -> None:
            pass  # pending remains, shown again at next startup

        def on_auto() -> None:
            self._apply_all_pending_suggestions()
            self.config["prompt_update_mode"] = "auto"
            self._update_mode_submenu_state()
            self.save_config()
            self.main_app.load_config_data(self.config)
            self.update_suggest_menu_badge()

        self._suggestions_panel.show(pending, on_accept, on_skip, on_auto)

    def _apply_all_pending_suggestions(self) -> None:
        """Add all pending candidates to user_terms and clear pending_suggestions."""
        from .app import _apply_candidates_to_user_terms
        pending = self.config.get("pending_suggestions") or {}
        if not pending:
            return
        _apply_candidates_to_user_terms(self.config, pending)
        for lang in pending:
            self._sync_prompt_file(lang)
        self.config["pending_suggestions"] = {}
        self.config["initial_prompt"] = build_initial_prompt(self.config)

    def save_config(self) -> None:
        """Persists current config to config.json."""
        save_config_to_disk(self.config)

    def check_for_updates(self, _: rumps.MenuItem) -> None:
        """Check GitHub for a newer release; notify and open release page if found."""
        if check_for_update(open_url_if_new=True):
            return
        self.main_app.notify("Обновления", "У вас установлена последняя версия.")

    def _toggle_ai_editor(self, sender) -> None:
        """Toggle the AI Editor on/off and persist the setting."""
        new_state = not (sender.state == 1)
        sender.state = 1 if new_state else 0
        self.main_app.update_config({"ai_editor_enabled": new_state})
        log_info(f"AI Editor {'enabled' if new_state else 'disabled'}.")
        if new_state:
            self.main_app.notify("AI Editor", "Загрузка модели... Вы получите уведомление о готовности.")
        else:
            self.main_app.notify("AI Editor", "Умная очистка отключена.")

    def _update_ai_backend_submenu_state(self) -> None:
        """Sync checkmarks on the backend submenu with current config."""
        backend = self.config.get("ai_editor_backend", "local")
        self._ai_backend_local_item.state = 1 if backend == "local" else 0
        self._ai_backend_gemini_item.state = 1 if backend == "gemini" else 0

    def _on_set_ai_backend_local(self, _) -> None:
        self.main_app.update_config({"ai_editor_backend": "local"})
        self._update_ai_backend_submenu_state()
        log_info("AI Editor backend set to: local")
        self.main_app.notify("AI Editor", "Бэкенд: Local (Qwen). Перезапустите приложение для смены модели.")

    def _on_set_ai_backend_gemini(self, _) -> None:
        self.main_app.update_config({"ai_editor_backend": "gemini"})
        self._update_ai_backend_submenu_state()
        log_info("AI Editor backend set to: gemini")
        self.main_app.notify("AI Editor", "Бэкенд: Gemini API. Перезапустите приложение для смены модели.")

    def _download_ai_model(self, _) -> None:
        """Open a new Terminal window and run the download script with visible progress."""
        script_path = str(get_config_path().parent / "scripts" / "download_ai_model.py")
        venv_python = str(get_config_path().parent / "venv" / "bin" / "python")
        python_bin = venv_python if os.path.exists(venv_python) else sys.executable

        import shlex
        q_python = shlex.quote(python_bin)
        q_script = shlex.quote(script_path)
        
        # AppleScript: open a new Terminal tab and run the download script
        applescript = (
            'tell application "Terminal"\n'
            "    activate\n"
            f'    do script "{q_python} {q_script}"\n'
            "end tell"
        )
        try:
            subprocess.run(["osascript", "-e", applescript], check=False)
            self.main_app.notify("AI Editor", "Загрузка начата в Терминале. Перезапустите приложение после завершения.")
        except Exception as e:
            log_error(f"Failed to open Terminal for download: {e}")
            self.main_app.notify("AI Editor", "Запустите вручную: python scripts/download_ai_model.py")

    def toggle_autostart(self, sender):
        current_state = sender.state == 1
        new_state = not current_state
        try:
            set_launch_at_login(new_state)
            sender.state = 1 if new_state else 0
            if new_state:
                self.main_app.notify("Автозапуск", "Приложение будет запускаться при входе в систему.")
            else:
                self.main_app.notify("Автозапуск", "Автозапуск отключён.")
        except Exception as e:
            log_error(f"Error toggling autostart: {e}")
            self.main_app.notify("Ошибка", "Не удалось изменить настройку автозапуска.")

    def restart_application(self, sender=None):
        log_info("Restart requested — cleaning up before relaunch.")
        try:
            self.main_app.stop()
        except Exception as e:
            log_error(f"Cleanup error on restart: {e}")
        # relaunch_app() spawns a detached shell that waits 1s then opens a new
        # instance, then kills the entire process group via SIGKILL.
        # Falls back to plain exit if not running from a .app bundle (dev mode).
        if not relaunch_app():
            log_info("Not running from .app bundle — skipping relaunch.")
            import os as _os
            import signal as _signal
            try:
                _os.killpg(_os.getpgrp(), _signal.SIGKILL)
            except Exception:
                _os._exit(0)

    def quit_application(self, sender=None):
        import os as _os
        import signal as _signal
        log_info("Quit requested — cleaning up before exit.")
        try:
            self.main_app.stop()
        except Exception as e:
            log_error(f"Cleanup error on quit: {e}")
        log_info("Cleanup complete — killing process group.")
        # Kill the entire process group so all child processes (transcriber, etc.) are
        # guaranteed to die. os._exit(0) bypasses atexit that would clean up daemon
        # multiprocessing children; os.killpg covers that gap.
        try:
            _os.killpg(_os.getpgrp(), _signal.SIGKILL)
        except Exception:
            _os._exit(0)

    def set_menubar_state(self, state: str) -> None:
        """Switch the menu bar icon. state: 'idle' | 'recording' | 'processing'"""
        self.icon = str(get_menubar_icon_path(state))

    def set_status(self, recording=False, processing=False):
        self.title = ""
        if recording:
            self.set_menubar_state("recording")
        elif processing:
            self.set_menubar_state("processing")
        else:
            self.set_menubar_state("idle")
