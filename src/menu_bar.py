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

_ICON_CACHED   = "\U0001f7e2"   # 🟢  — model is on disk, instant switch
_ICON_DOWNLOAD = "\u2b07\ufe0f"  # ⬇️  — model needs to download

from .log_analyzer import generate_terms_hint_from_history
from .phrase_history import get_last_phrases
from .updater import check_for_update
from .permissions import check_input_monitoring, open_input_monitoring_settings
from .autostart import is_launch_at_login_enabled, set_launch_at_login
from .utils import (
    build_initial_prompt,
    copy_to_clipboard,
    get_config_path,
    get_log_file_path,
    get_menu_icon_path,
    get_primary_language,
    get_ui_strings,
    is_accessibility_trusted,
    log_error,
    log_info,
    open_accessibility_settings,
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
# Whisper initial-prompt hints — shared by LanguageSelectionPanel and _update_language_hint_and_prompt
LANG_PROMPTS = {
    "ru": "Русский язык.",
    "en": "English language.",
    "de": "Deutscher Text.",
    "es": "Texto en español.",
    "fr": "Texte en français.",
}

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
            from AppKit import NSMenu, NSMenuItem, NSButton, NSTextField, NSFont, \
                NSButtonTypeMomentaryLight, NSTextAlignmentLeft, NSTextAlignmentCenter

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
                self._ns_menu.addItem_(self._phrase_item(i, f"📋  {title}"))

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
            from AppKit import NSMenuItem, NSButton, NSButtonTypeMomentaryLight, NSTextAlignmentLeft
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

        def loadMoreClicked_(self, sender) -> None:
            self._page_count += 5
            self._do_rebuild()

    _HAVE_PHRASE_MENU = True

except Exception as _lang_menu_exc:
    import logging as _logging
    _logging.getLogger(__name__).error("Language submenu unavailable: %s", _lang_menu_exc)
    _LangMenuController = None  # type: ignore
    _HAVE_LANG_MENU = False
    _PhraseMenuController = None  # type: ignore
    _HAVE_PHRASE_MENU = False


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
        self.main_app = main_app
        self.config = main_app.config
        self._last_prompt_mtime = 0.0
        self._accessibility_granted = is_accessibility_trusted()
        self._accessibility_item = None  # set in setup_menu
        self._input_monitoring_ok: bool | None = None  # None = unknown until health check
        self._input_monitoring_item = None  # set in setup_menu
        self._wizard_pending = False
        self._lang_menu_controller: "_LangMenuController | None" = None
        self._phrase_menu_controller: "_PhraseMenuController | None" = None
        self._phrases_page_count: int = 5  # used only in the rumps fallback path

        # Build Menu
        self.setup_menu()

        # Hook tap-failure callback after menu is built so _input_monitoring_item exists
        self.main_app.hotkey_handler.on_tap_failed = self._on_tap_failed
        self._migrate_old_prompt()
        # Asynchronously check which Whisper models are already cached
        self._start_model_cache_check()

    def _migrate_old_prompt(self):
        """Migrates a single initial_prompt.txt into custom_prompts mapping on first launch."""
        custom_dict = self.config.get("custom_prompts")
        if custom_dict is None:
            old_path = get_config_path().parent / "initial_prompt.txt"
            lang = get_primary_language(self.config)
            
            custom_dict = {}
            if old_path.exists():
                try:
                    with open(old_path, "r", encoding="utf-8") as f:
                        old_txt = f.read().strip()
                    if old_txt:
                        custom_dict[lang] = old_txt
                        self.config["initial_prompt"] = old_txt
                except Exception:
                    pass
            self.config["custom_prompts"] = custom_dict
            self.save_config()

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
        """Watches initial_prompt_{lang}.txt for manual edits by the user."""
        lang = get_primary_language(self.config)
        prompt_path = self._get_prompt_path(lang)
        if not prompt_path.exists():
            return
            
        try:
            mtime = prompt_path.stat().st_mtime
            if getattr(self, "_last_prompt_mtime", 0.0) == 0.0 or getattr(self, "_last_prompt_path", None) != prompt_path:
                self._last_prompt_mtime = mtime
                self._last_prompt_path = prompt_path
                return
                
            if mtime > self._last_prompt_mtime:
                self._last_prompt_mtime = mtime
                with open(prompt_path, "r", encoding="utf-8") as f:
                    new_prompt = f.read().strip()
                
                custom_dict = self.config.get("custom_prompts", {})
                previous = custom_dict.get(lang, "")
                
                if previous != new_prompt:
                    if previous:
                        prev_dict = self.config.get("previous_prompts", {})
                        prev_dict[lang] = previous
                        self.config["previous_prompts"] = prev_dict
                        
                    custom_dict[lang] = new_prompt
                    self.config["custom_prompts"] = custom_dict
                    self.config["initial_prompt"] = new_prompt
                    
                    self.save_config()
                    self.main_app.load_config_data(self.config)
                    log_info(f"Initial prompt updated manually for {lang.upper()}.")
                    self.main_app.notify("Настройки", f"Подсказка для {lang.upper()} обновлена!")
        except Exception as e:
            log_error(f"Error checking prompt file: {e}")

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
        # Check Input Monitoring once after NSApp has started
        if self._input_monitoring_ok is None:
            self._input_monitoring_ok = check_input_monitoring()
            self._update_input_monitoring_item()
            if not self._input_monitoring_ok:
                log_error(
                    "Input Monitoring permission not granted — hotkeys will not work. "
                    "Add Click-n-speak to Privacy & Security → Input Monitoring."
                )

        if not self._wizard_pending:
            return
        self._wizard_pending = False
        try:
            from .setup_wizard import run_setup_wizard
            run_setup_wizard()
            # Refresh accessibility status indicator after wizard
            self._accessibility_granted = is_accessibility_trusted()
            self._update_accessibility_menu_item()
        except Exception as exc:
            log_error(f"Setup wizard error: {exc}")

    def _on_check_permissions(self, _) -> None:
        """Menu item: re-run the permission wizard on demand."""
        try:
            from .permissions import reset_setup
            from .setup_wizard import run_setup_wizard
            reset_setup()
            run_setup_wizard()
            self._accessibility_granted = is_accessibility_trusted()
            self._update_accessibility_menu_item()
            self._input_monitoring_ok = check_input_monitoring()
            self._update_input_monitoring_item()
            # Wizard shows its own restart prompt on completion; no auto-restart here.
        except Exception as exc:
            log_error(f"Check permissions failed: {exc}")

    @rumps.timer(5.0)
    def _check_accessibility_status(self, _):
        """Periodically refresh permission indicators.

        Does NOT auto-restart the hotkey listener — on macOS 15+, starting the
        pynput listener after permissions flip live triggers a TSM crash.
        Instead we prompt the user to relaunch the app.
        """
        from .setup_wizard import is_wizard_active
        try:
            trusted = is_accessibility_trusted()
            if trusted != self._accessibility_granted:
                self._accessibility_granted = trusted
                self._update_accessibility_menu_item()

            if trusted:
                im_ok = check_input_monitoring()
                if im_ok != self._input_monitoring_ok:
                    self._input_monitoring_ok = im_ok
                    self._update_input_monitoring_item()

            # If all permissions are now granted but the listener isn't running,
            # the user must restart. Prompt once (wizard handles its own prompt).
            if (
                trusted
                and self._input_monitoring_ok
                and not self.main_app.hotkey_handler.is_listener_alive()
                and not is_wizard_active()
                and not getattr(self, "_restart_prompt_shown", False)
            ):
                self._restart_prompt_shown = True
                _prompt_restart("All required permissions are now granted.")
        except Exception as e:
            log_error(f"Error in accessibility status check: {e}")

    def _update_accessibility_menu_item(self) -> None:
        if self._accessibility_item is None:
            return
        if self._accessibility_granted:
            self._accessibility_item.title = "✅ Accessibility Granted"
        else:
            self._accessibility_item.title = "⚠️ Accessibility Required"

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
            self._input_monitoring_item.title = "⌨️ Input Monitoring (checking…)"
        elif self._input_monitoring_ok:
            self._input_monitoring_item.title = "✅ Input Monitoring Granted"
        else:
            self._input_monitoring_item.title = "⚠️ Input Monitoring Required"

    def _on_input_monitoring_click(self, _) -> None:
        if not self._input_monitoring_ok:
            open_input_monitoring_settings()
        else:
            self.main_app.notify("Доступ", "Input Monitoring уже разрешён.")

    def setup_menu(self):
        # Accessibility + Input Monitoring status at the top
        self._accessibility_item = rumps.MenuItem("", callback=self._on_accessibility_click)
        self._update_accessibility_menu_item()
        self.menu.add(self._accessibility_item)
        self._input_monitoring_item = rumps.MenuItem("", callback=self._on_input_monitoring_click)
        self._update_input_monitoring_item()
        self.menu.add(self._input_monitoring_item)
        self.menu.add(rumps.MenuItem("🔐 Check Permissions", callback=self._on_check_permissions))
        self.menu.add(None)  # Separator

        # Model selection submenu
        current_model = self.config.get("model_name", "mlx-community/whisper-large-v3-turbo")
        self.menu.add("Model")
        for label, model_id in WHISPER_MODELS:
            title = f"{_ICON_DOWNLOAD} {label}"
            item = rumps.MenuItem(title, callback=self.change_model)
            if model_id == current_model:
                item.state = 1
            self.menu["Model"].add(item)

        # Language selection — native submenu, stays open after clicks via NSMenuItem.setView_()
        lang_item = rumps.MenuItem("🌐 Languages")
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
        ai_editor_item = rumps.MenuItem("✦ AI Editor (Punctuation & Cleanup)", callback=self._toggle_ai_editor)
        ai_editor_item.state = 1 if self.config.get("ai_editor_enabled", False) else 0
        self.menu.add(ai_editor_item)
        self.menu.add(rumps.MenuItem("  ↳ Download AI Editor Model", callback=self._download_ai_model))

        # Initial Prompt submenu
        prompt_menu = rumps.MenuItem("📝 Initial Prompt")
        prompt_menu.add(rumps.MenuItem("Edit...", callback=self.edit_initial_prompt))
        prompt_menu.add(rumps.MenuItem("Update from History", callback=self.update_initial_prompt_from_history))
        prompt_menu.add(rumps.MenuItem("Revert to Previous", callback=self.revert_initial_prompt))
        self.menu.add(prompt_menu)

        # Phrase history
        self._last_phrases_parent = rumps.MenuItem("Last Phrases")
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

        self.menu.add(rumps.MenuItem("🎵 Transcribe Audio File...", callback=self.transcribe_audio_file))

        self.menu.add(None)  # Separator

        self.menu.add(rumps.MenuItem("🔄 Check for Updates", callback=self.check_for_updates))

        # Autostart
        autostart_item = rumps.MenuItem("🚀 Launch at Login", callback=self.toggle_autostart)
        autostart_item.state = 1 if is_launch_at_login_enabled() else 0
        self.menu.add(autostart_item)

        # Advanced submenu
        advanced_menu = rumps.MenuItem("⚙️ Advanced")
        advanced_menu.add(rumps.MenuItem("Edit Config File", callback=self.open_config))
        advanced_menu.add(rumps.MenuItem("Open Log File", callback=self.open_log_file))
        advanced_menu.add(rumps.MenuItem("Reload Configuration", callback=self.reload_config))
        self.menu.add(advanced_menu)

        self.menu.add(rumps.MenuItem("🔁 Restart", callback=self.restart_application))
        self.menu.add(None)

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
                icon = _ICON_CACHED
            except Exception:
                icon = _ICON_DOWNLOAD

            new_title = f"{icon} {label}"

            def _apply(title: str = new_title, lbl: str = label) -> None:
                try:
                    for item in self.menu["Model"].values():
                        # Strip any existing icon prefix to compare base labels
                        base = item.title
                        for pfx in (_ICON_CACHED, _ICON_DOWNLOAD):
                            if base.startswith(pfx):
                                base = base[len(pfx):].lstrip()
                        if base == lbl:
                            item.title = title
                            break
                except Exception as exc:
                    log_error(f"Model cache indicator update failed for '{lbl}': {exc}")

            # Post to main-thread queue so rumps UI stays thread-safe
            if hasattr(self.main_app, "_main_thread_queue"):
                self.main_app._main_thread_queue.put((_apply, [], {}))
            else:
                _apply()

    def change_model(self, sender):
        # Strip cache-status icon prefix (e.g. "🟢 Turbo" → "Turbo")
        clean_label = sender.title
        for pfx in (_ICON_CACHED, _ICON_DOWNLOAD):
            if clean_label.startswith(pfx):
                clean_label = clean_label[len(pfx):].lstrip()

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
        self._last_prompt_path = None
        self._last_prompt_mtime = 0.0

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
        """Setup initial_prompt: use user's custom text if exists, else generate a fresh auto-hint."""
        primary = get_primary_language(self.config)
        additional = self.config.get("additional_languages") or []

        custom_dict = self.config.get("custom_prompts", {})
        if primary in custom_dict and custom_dict[primary].strip():
            # Apply user's custom prompt for this language
            final_prompt = custom_dict[primary].strip()
        else:
            # Build and write a new base auto-hint for this language
            main_prompt = LANG_PROMPTS.get(primary, "")
            extra_prompts_list = [LANG_PROMPTS.get(str(l), "") for l in additional if LANG_PROMPTS.get(str(l))]
            extra_prompts = " ".join(extra_prompts_list)
            final_prompt = f"{main_prompt} {extra_prompts}".strip()
            
            # Save it so it appears correctly if the user clicks "Edit Initial Prompt"
            custom_dict[primary] = final_prompt
            self.config["custom_prompts"] = custom_dict
            
            try:
                prompt_path = self._get_prompt_path(primary)
                with open(prompt_path, "w", encoding="utf-8") as f:
                    f.write(final_prompt)
            except Exception as e:
                log_error(f"Failed to auto-write warmup prompt for {primary}: {e}")
            
        self.config["initial_prompt"] = final_prompt

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
        for i, (_ts, text) in enumerate(reversed(phrases)):
            title = (text[: max_title_len - 1] + "…") if len(text) > max_title_len else text
            if not title:
                title = "(empty)"
            # Append zero-width spaces so identical display titles remain unique rumps keys,
            # preventing NSMenuItem leaks when the same phrase appears multiple times.
            unique_title = f"📋  {title}" + "​" * i
            parent.add(
                rumps.MenuItem(unique_title, callback=lambda s, t=text: copy_to_clipboard(t))
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
        """Opens the language-specific initial prompt in a text editor."""
        lang = get_primary_language(self.config)
        current_prompt = str(self.config.get("initial_prompt", ""))
            
        prompt_path = self._get_prompt_path(lang)
        try:
            with open(prompt_path, "w", encoding="utf-8") as f:
                f.write(current_prompt)
            self._last_prompt_mtime = prompt_path.stat().st_mtime
            self._last_prompt_path = prompt_path
            subprocess.run(["open", "-t", str(prompt_path)], check=False)
        except OSError as e:
            log_error(f"Failed to open initial prompt for editing: {e}")

    def update_initial_prompt_from_history(self, _: rumps.MenuItem) -> None:
        """Builds a new initial prompt from recent phrase history and applies it."""
        terms_hint = generate_terms_hint_from_history()
        if not terms_hint:
            self.main_app.notify("Настройки", "Не удалось сгенерировать подсказки из истории.")
            return

        lang = get_primary_language(self.config)
        custom_dict = self.config.get("custom_prompts", {})
        previous = custom_dict.get(lang, "")
        
        current_prompt = str(self.config.get("initial_prompt", "")).strip()
        new_prompt = f"{current_prompt}\n{terms_hint}".strip()
        
        if previous:
            prev_dict = self.config.get("previous_prompts", {})
            prev_dict[lang] = previous
            self.config["previous_prompts"] = prev_dict

        custom_dict[lang] = new_prompt
        self.config["custom_prompts"] = custom_dict
        self.config["initial_prompt"] = new_prompt
        
        prompt_path = self._get_prompt_path(lang)
        try:
            with open(prompt_path, "w", encoding="utf-8") as f:
                f.write(new_prompt)
        except Exception:
            pass

        self.save_config()
        self.main_app.load_config_data(self.config)
        self.main_app.notify("Настройки", f"Термины добавлены для {lang.upper()}.")

    def revert_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Reverts initial_prompt to the previous version if available."""
        lang = get_primary_language(self.config)
        previous_prompts = self.config.get("previous_prompts", {})
        prev = previous_prompts.get(lang, "")
        
        if not prev:
            self.main_app.notify("Настройки", f"Нет предыдущей версии подсказки для {lang.upper()}.")
            return

        custom_dict = self.config.get("custom_prompts", {})
        current = custom_dict.get(lang, "")
        
        custom_dict[lang] = prev
        previous_prompts[lang] = current
        
        self.config["custom_prompts"] = custom_dict
        self.config["previous_prompts"] = previous_prompts
        self.config["initial_prompt"] = prev
        
        prompt_path = self._get_prompt_path(lang)
        try:
            with open(prompt_path, "w", encoding="utf-8") as f:
                f.write(prev)
        except Exception:
            pass

        self.save_config()
        self.main_app.load_config_data(self.config)
        self.main_app.notify("Настройки", f"Подсказка для {lang.upper()} восстановлена.")

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

    def set_status(self, recording=False, processing=False):
        # Make the state highly visible in the menu bar; language from primary setting.
        s = get_ui_strings(get_primary_language(self.config))
        if recording:
            self.title = s["menu_recording"]
        elif processing:
            self.title = s["menu_processing"]
        else:
            self.title = ""
