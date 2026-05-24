import os
import queue
import subprocess
import sys
import threading
from datetime import datetime, timezone

import rumps
from . import i18n

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

# Approximate download sizes shown in the "model not cached" alert.
WHISPER_MODEL_SIZES: dict[str, str] = {
    "mlx-community/whisper-large-v3-turbo": "~795 MB",
    "mlx-community/whisper-large-v3-mlx":   "~1.5 GB",
    "mlx-community/whisper-medium-mlx":      "~790 MB",
    "mlx-community/whisper-small-mlx":       "~244 MB",
    "mlx-community/whisper-base-mlx":        "~74 MB",
}

_ICON_CACHED = "🟢"  # 🟢  — model is on disk, instant switch
_RECOMMENDED_MODEL = "mlx-community/whisper-large-v3-turbo"


_MODEL_ROW_W = 220.0   # default row width; the menu column may be wider
_MODEL_ROW_H = 22.0

_HAVE_MODEL_ROWS = False
try:
    from Foundation import NSObject as _NSObjectRow  # type: ignore
    import objc as _objc_row  # type: ignore
    from AppKit import (  # type: ignore
        NSMenu as _NSMenuRow, NSMenuItem as _NSMenuItemRow,
        NSView as _NSViewRow, NSButton as _NSButtonRow,
        NSTextField as _NSTextFieldRow, NSImageView as _NSImageViewRow,
        NSImage as _NSImageRow, NSFont as _NSFontRow,
        NSButtonTypeMomentaryPushIn as _NSBtnTypePush,
        NSMakeRect as _NSMakeRectRow,
    )

    class _ModelRowDelegate(_NSObjectRow):
        """Per-model ObjC target: routes 'switch' and 'delete' button actions."""

        _ns_menu = None
        _switch_fn = None
        _delete_fn = None

        @_objc_row.python_method
        def configure(self, ns_menu, switch_fn, delete_fn) -> "_ModelRowDelegate":
            self._ns_menu = ns_menu
            self._switch_fn = switch_fn
            self._delete_fn = delete_fn
            return self

        def switchClicked_(self, sender) -> None:
            if self._ns_menu is not None:
                self._ns_menu.cancelTracking()
            if self._switch_fn:
                self._switch_fn()

        def deleteClicked_(self, sender) -> None:
            if self._ns_menu is not None:
                self._ns_menu.cancelTracking()
            if self._delete_fn:
                self._delete_fn()

    def _build_model_row_ns_item(delegate: "_ModelRowDelegate"):
        """Return (NSMenuItem, icon_view, label_field, trash_btn) with inline layout:
        [icon_view][label_field  …  ][trash_btn]  all in one row.
        """
        w, h = _MODEL_ROW_W, _MODEL_ROW_H
        trash_w = 20.0
        switch_w = w - trash_w - 4.0

        container = _NSViewRow.alloc().initWithFrame_(_NSMakeRectRow(0, 0, w, h))

        # Left icon (NSImageView)
        icon_view = _NSImageViewRow.alloc().initWithFrame_(
            _NSMakeRectRow(4, (h - 16) / 2, 16, 16)
        )
        container.addSubview_(icon_view)

        # Label text
        label_field = _NSTextFieldRow.labelWithString_("")
        label_field.setFrame_(_NSMakeRectRow(24, (h - 16) / 2, switch_w - 28, 16))
        label_field.setFont_(_NSFontRow.menuFontOfSize_(0))
        container.addSubview_(label_field)

        # Transparent full-row switch button (on top of icon + label)
        switch_btn = _NSButtonRow.alloc().initWithFrame_(
            _NSMakeRectRow(0, 0, switch_w, h)
        )
        switch_btn.setTitle_("")
        switch_btn.setBordered_(False)
        switch_btn.setButtonType_(_NSBtnTypePush)
        switch_btn.cell().setHighlightsBy_(0)  # no visual flash on click
        switch_btn.setTarget_(delegate)
        switch_btn.setAction_("switchClicked:")
        container.addSubview_(switch_btn)

        # Trash button (right side, initially hidden)
        trash_btn = _NSButtonRow.alloc().initWithFrame_(
            _NSMakeRectRow(switch_w + 2, (h - 16) / 2, 16, 16)
        )
        trash_img = _NSImageRow.imageWithSystemSymbolName_accessibilityDescription_(
            "trash", None
        )
        if trash_img:
            trash_btn.setImage_(trash_img)
        trash_btn.setBordered_(False)
        trash_btn.setHidden_(True)
        trash_btn.setTarget_(delegate)
        trash_btn.setAction_("deleteClicked:")
        container.addSubview_(trash_btn)

        ns_item = _NSMenuItemRow.alloc().init()
        ns_item.setView_(container)
        return ns_item, icon_view, label_field, trash_btn

    _HAVE_MODEL_ROWS = True
except Exception as _model_row_exc:
    import logging as _logging_mr
    _logging_mr.getLogger(__name__).error(
        "Custom model row views unavailable: %s", _model_row_exc
    )
    _ModelRowDelegate = None  # type: ignore
    _build_model_row_ns_item = None  # type: ignore

# Byte sizes for disk-space preflight check (with 20% safety margin in _preflight_download)
_MODEL_SIZE_BYTES: dict[str, int] = {
    "mlx-community/whisper-large-v3-turbo":  795_000_000,
    "mlx-community/whisper-large-v3-mlx":  1_500_000_000,
    "mlx-community/whisper-medium-mlx":     790_000_000,
    "mlx-community/whisper-small-mlx":      244_000_000,
    "mlx-community/whisper-base-mlx":        74_000_000,
}

from .ai_editor import get_gemini_api_key, set_gemini_api_key
from .phrase_history import get_last_phrases
from .updater import check_for_update
from .permissions import (
    check_input_monitoring,
    check_microphone,
    open_input_monitoring_settings,
    open_microphone_settings,
)
from .autostart import is_launch_at_login_enabled, set_launch_at_login
from .correction_analyzer import remove_replacement_pair_from_index
from .dataset_logger import _DEFAULT_DATASET_PATH
from .metrics import dead_weight_terms, top_helping_terms
from .replacements_panel import ReplacementsPanel
from .vocab_provider import list_replacement_rows_for_ui, normalize_replacement_side
from .utils import (
    _term_str,
    build_initial_prompt,
    canonical_term_key,
    canonicalize_term,
    copy_to_clipboard,
    deduplicate_prompt_terms,
    get_allowed_languages,
    get_config_path,
    get_log_file_path,
    get_menu_icon_path,
    get_menu_item_icon_path,
    get_menubar_icon_path,
    get_metrics_history_path,
    get_primary_language,
    is_accessibility_trusted,
    log_error,
    log_exception,
    log_info,
    normalize_lang_code,
    open_accessibility_settings,
    parse_prompt_terms,
    relaunch_app,
    save_config_to_disk,
    send_notification,
    write_text_atomic,
)


# ---------------------------------------------------------------------------
# Language Selection Panel (NSPanel — stays open across multiple clicks)
# ---------------------------------------------------------------------------

LANGS = ["ru", "en", "de", "es", "fr", "it", "pt", "nl", "pl", "uk", "tr", "zh", "ja", "ko", "ar"]
LANG_LABELS = {
    "ru": "RU — Russian",
    "en": "EN — English",
    "de": "DE — German",
    "es": "ES — Spanish",
    "fr": "FR — French",
    "it": "IT — Italian",
    "pt": "PT — Portuguese",
    "nl": "NL — Dutch",
    "pl": "PL — Polish",
    "uk": "UA — Ukrainian",
    "tr": "TR — Turkish",
    "zh": "ZH — Chinese",
    "ja": "JA — Japanese",
    "ko": "KO — Korean",
    "ar": "AR — Arabic",
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

            self._ns_menu.addItem_(self._header_item(i18n.t("menu.history_hint")))
            self._ns_menu.addItem_(NSMenuItem.separatorItem())

            if not self._phrases:
                self._ns_menu.addItem_(self._header_item(i18n.t("menu.history_empty")))
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
            btn.setTitle_(i18n.t("menu.show_more"))
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
            lbl.setStringValue_(i18n.t("popup.copied"))
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


try:
    import objc as _objc_prompt_terms  # type: ignore
    from AppKit import NSObject as _NSObjectPromptTerms  # type: ignore

    class _PromptTermsPanelDelegate(_NSObjectPromptTerms):
        """Save/Cancel targets + window close cleanup for the prompt-terms editor panel."""

        _owner = None
        _lang = None

        @_objc_prompt_terms.python_method
        def configure(self, owner: "ClickNSpeakApp", lang: str) -> "_PromptTermsPanelDelegate":
            self._owner = owner
            self._lang = lang
            return self

        def saveClicked_(self, sender) -> None:
            owner = self._owner
            lang = self._lang
            if owner is not None and lang is not None:
                owner._prompt_terms_editor_save(lang)

        def cancelClicked_(self, sender) -> None:
            owner = self._owner
            if owner is not None:
                owner._prompt_terms_editor_cancel()

        def deleteInactiveClicked_(self, sender) -> None:
            owner = self._owner
            if owner is not None:
                owner._prompt_terms_editor_delete_inactive()

        def windowWillClose_(self, notification) -> None:
            owner = self._owner
            if owner is not None:
                owner._prompt_terms_editor_closed()

    _HAVE_PROMPT_TERMS_PANEL = True
except Exception:
    _PromptTermsPanelDelegate = None  # type: ignore
    _HAVE_PROMPT_TERMS_PANEL = False


def _prompt_restart(reason: str) -> None:
    """Show a modal asking the user to relaunch the app. Relaunches on OK."""
    try:
        from AppKit import NSAlert  # type: ignore
        alert = NSAlert.alloc().init()
        alert.setAlertStyle_(1)
        alert.setMessageText_(i18n.t("dialog.restart_title"))
        alert.setInformativeText_(i18n.t("dialog.restart_body", reason=reason))
        alert.addButtonWithTitle_(i18n.t("btn.restart_now"))
        alert.addButtonWithTitle_(i18n.t("btn.later"))
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
        self._model_menu_item = None  # set in setup_menu
        self._permissions_item = None  # parent Permissions menu item
        self._wizard_pending = False
        self._language_picker_pending = False
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

        # Download state — tracks in-progress and errored downloads
        self._download_state: dict[str, str] = {}   # model_id → "downloading" | "partial" | "error"
        self._download_progress: dict[str, int] = {}  # model_id → percent 0..100
        self._partial_bytes: dict[str, int] = {}      # model_id → bytes downloaded before cancel
        self._cached_models: dict[str, bool] = {}    # model_id → True if in HF cache
        self._download_panel = None   # ModelDownloadPanel instance (at most one active)
        self._downloader = None       # ModelDownloader instance (at most one active)
        self._model_row_refs: dict[str, dict] = {}  # model_id → {ns_item, icon_view, label, trash_btn, delegate}
        self._prompt_terms_panel = None
        self._prompt_terms_text_view = None
        self._prompt_terms_delegate = None
        self._prompt_terms_stats_label = None
        self._prompt_terms_delete_btn = None
        self._replacements_panel: "ReplacementsPanel | None" = None
        self._terms_panel = None  # TermsPanel instance (lazy)

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
        lang = normalize_lang_code(lang)
        return get_config_path().parent / f"initial_prompt_{lang}.txt"

    @staticmethod
    def _get_legacy_ua_prompt_path():
        """Legacy fallback path kept for backward compatibility with old configs."""
        return get_config_path().parent / "initial_prompt_ua.txt"

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

    @rumps.timer(3600)
    def _decay_tick(self, _) -> None:
        """Hourly timer: runs daily maintenance tasks at most once per 24 h."""
        app = self.main_app
        if app is not None and hasattr(app, "run_daily_maintenance_if_due"):
            try:
                app.run_daily_maintenance_if_due()
            except Exception as exc:
                log_error(f"Daily maintenance tick failed: {exc}")

    @rumps.timer(60)
    def _flush_dirty_config_tick(self, _) -> None:
        """Periodic flush of term-usage counters updated in the injection hot-path."""
        app = self.main_app
        if app is not None and hasattr(app, "flush_dirty_config_if_needed"):
            try:
                app.flush_dirty_config_if_needed()
            except Exception as exc:
                log_error(f"Flush dirty config tick failed: {exc}")

    def _merge_prompt_terms_text_for_lang(
        self,
        lang: str,
        new_text: str,
        *,
        allow_empty: bool = False,
    ) -> bool:
        """Parse comma/newline term text into ``user_terms[lang]``. Returns True if config changed.

        When ``allow_empty`` is False, an empty string while terms already exist is ignored
        (guards against a truncated write when syncing from ``initial_prompt_*.txt``).
        """
        lang = normalize_lang_code(lang)
        user_terms = dict(self.config.get("user_terms") or {})
        previous_terms = list(user_terms.get(lang, []))
        stripped = (new_text or "").strip()

        if not stripped and previous_terms and not allow_empty:
            log_info(
                f"_merge_prompt_terms_text_for_lang: ignoring empty edit for {lang} "
                f"({len(previous_terms)} terms in config; partial-write guard)"
            )
            return False

        new_term_strings = deduplicate_prompt_terms(parse_prompt_terms(stripped))

        existing_dicts = {
            canonical_term_key(_term_str(t)): t
            for t in previous_terms
            if isinstance(t, dict)
        }
        now_iso = datetime.now(timezone.utc).isoformat()
        new_terms_as_items = []
        for ts in new_term_strings:
            term = canonicalize_term(ts)
            if not term:
                continue
            lower = canonical_term_key(term)
            if lower in existing_dicts:
                new_terms_as_items.append(existing_dicts[lower])
            else:
                new_terms_as_items.append({
                    "term": term,
                    "source": "manual",
                    "added_at": now_iso,
                    "last_seen": now_iso,
                    "use_count": 0,
                })

        prev_strs = [_term_str(t) for t in previous_terms]
        if prev_strs == new_term_strings:
            return False

        if previous_terms:
            snapshots = dict(self.config.get("prompt_snapshots", {}))
            snapshots[lang] = previous_terms
            self.config["prompt_snapshots"] = snapshots

        user_terms[lang] = new_terms_as_items
        self.config["user_terms"] = user_terms
        self.config["initial_prompt"] = build_initial_prompt(self.config)
        return True

    @rumps.timer(1.0)
    def _watch_prompt_file(self, _):
        """Watches initial_prompt_{lang}.txt for all active languages; updates user_terms on change."""
        primary = get_primary_language(self.config)
        additional = list(self.config.get("additional_languages") or [])
        all_langs = [primary] + [l for l in additional if l != primary]

        for lang in all_langs:
            prompt_path = self._get_prompt_path(lang)
            source_path = prompt_path
            legacy_path = self._get_legacy_ua_prompt_path()
            if (
                normalize_lang_code(lang) == "uk"
                and not prompt_path.exists()
                and legacy_path.exists()
            ):
                source_path = legacy_path
            if not source_path.exists():
                continue
            try:
                mtime = source_path.stat().st_mtime
                if self._prompt_mtimes.get(lang, 0.0) == 0.0:
                    self._prompt_mtimes[lang] = mtime
                    continue

                if mtime > self._prompt_mtimes[lang]:
                    self._prompt_mtimes[lang] = mtime
                    with source_path.open("r", encoding="utf-8") as f:
                        new_text = f.read().strip()

                    # Guard against a partially-written file (e.g. crash during an
                    # earlier non-atomic write): an empty file while terms exist in
                    # config means the write never completed — skip this change.
                    user_terms = dict(self.config.get("user_terms") or {})
                    if not new_text and user_terms.get(lang):
                        log_info(
                            f"_watch_prompt_file: ignoring empty {prompt_path.name} "
                            f"(config has {len(user_terms[lang])} terms; likely corrupt write)"
                        )
                        continue
                    if self._merge_prompt_terms_text_for_lang(lang, new_text, allow_empty=False):
                        self.save_config()
                        self.main_app.load_config_data(self.config)
                        if source_path != prompt_path:
                            # Legacy ua-file was edited; mirror content to canonical uk-file.
                            self._sync_prompt_file(lang)
                        log_info(f"Initial prompt updated manually for {lang.upper()}.")
                        self.main_app.notify(i18n.t("notify.settings_title"), i18n.t("notify.prompt_updated_body", lang=lang.upper()))
            except Exception as e:
                log_error(f"Error checking prompt file for {lang}: {e}")

    # ------------------------------------------------------------------
    # Setup wizard
    # ------------------------------------------------------------------

    def schedule_language_picker(self, run_wizard_after: bool = False) -> None:
        """Show the language picker on first launch before the setup wizard."""
        self._language_picker_pending = True
        if run_wizard_after:
            self._wizard_pending = True  # will be re-set after picker

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

        if self._language_picker_pending:
            self._language_picker_pending = False
            was_wizard_pending = self._wizard_pending
            self._wizard_pending = False  # picker callback will re-schedule wizard
            try:
                from .language_picker import show_if_needed as _show_lp

                def _after_lang_pick() -> None:
                    if was_wizard_pending:
                        self._wizard_pending = True

                _show_lp(self.config, _after_lang_pick)
            except Exception as exc:
                log_error(f"Language picker error: {exc}")
                if was_wizard_pending:
                    self._wizard_pending = True
            return  # wizard runs on the next 1s tick

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
            self._microphone_item.title = i18n.t("menu.mic_granted")
            p = get_menu_item_icon_path("microphone-ok")
        else:
            self._microphone_item.title = i18n.t("menu.mic_required")
            p = get_menu_item_icon_path("microphone-warn")
        if p:
            self._microphone_item.set_icon(str(p), dimensions=[16, 16], template=False)
        self._update_permissions_parent_item()

    def _on_microphone_click(self, _) -> None:
        if not self._microphone_ok:
            open_microphone_settings()
        else:
            self.main_app.notify(i18n.t("notify.perm_title"), i18n.t("notify.perm_mic_granted"))

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
            self._accessibility_item.title = i18n.t("menu.access_granted")
            p = get_menu_item_icon_path("accessibility-ok")
        else:
            self._accessibility_item.title = i18n.t("menu.access_required")
            p = get_menu_item_icon_path("accessibility-warn")
        if p:
            self._accessibility_item.set_icon(str(p), dimensions=[16, 16], template=False)
        self._update_permissions_parent_item()

    def _on_accessibility_click(self, _) -> None:
        if not self._accessibility_granted:
            open_accessibility_settings()
        else:
            self.main_app.notify(i18n.t("notify.perm_title"), i18n.t("notify.perm_access_granted"))

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
                i18n.t("notify.perm_hotkeys_disabled_title"),
                i18n.t("notify.perm_hotkeys_disabled_body"),
            )

    def _update_input_monitoring_item(self) -> None:
        if self._input_monitoring_item is None:
            return
        if self._input_monitoring_ok is None:
            self._input_monitoring_item.title = i18n.t("menu.input_checking")
            p = get_menu_item_icon_path("input-monitoring-warn")
        elif self._input_monitoring_ok:
            self._input_monitoring_item.title = i18n.t("menu.input_granted")
            p = get_menu_item_icon_path("input-monitoring-ok")
        else:
            self._input_monitoring_item.title = i18n.t("menu.input_required")
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
            self.main_app.notify(i18n.t("notify.perm_title"), i18n.t("notify.perm_input_granted"))

    def setup_menu(self):
        def _icon(name: str) -> dict:
            p = get_menu_item_icon_path(name)
            return {"icon": str(p), "dimensions": [16, 16], "template": True} if p else {}

        # Permissions parent item with submenu
        self._permissions_item = rumps.MenuItem(i18n.t("menu.permissions"))
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
        self._model_menu_item = rumps.MenuItem(i18n.t("menu.model"), **_icon("model"))
        self.menu.add(self._model_menu_item)

        if _HAVE_MODEL_ROWS:
            model_ns_menu = _NSMenuRow.alloc().initWithTitle_("Model")
            model_ns_menu.setAutoenablesItems_(False)
            self._model_menu_item._menuitem.setSubmenu_(model_ns_menu)

            for label, model_id in WHISPER_MODELS:
                delegate = _ModelRowDelegate.alloc().init().configure(
                    ns_menu=model_ns_menu,
                    switch_fn=lambda mid=model_id, lbl=label: self._do_switch_model(mid, lbl),
                    delete_fn=lambda mid=model_id, lbl=label: self._confirm_and_delete_model(lbl, mid),
                )
                ns_item, icon_view, lbl_field, trash_btn = _build_model_row_ns_item(delegate)
                size = WHISPER_MODEL_SIZES.get(model_id, "?")
                lbl_field.setStringValue_(f"{label} · {size}")
                ns_item.setState_(1 if model_id == current_model else 0)
                model_ns_menu.addItem_(ns_item)

                self._model_row_refs[model_id] = {
                    "ns_item": ns_item,
                    "icon_view": icon_view,
                    "label": lbl_field,
                    "trash_btn": trash_btn,
                    "delegate": delegate,
                }
        else:
            # Fallback: plain rumps items (no inline trash button)
            _dl_icon = get_menu_item_icon_path("download-model")
            for label, model_id in WHISPER_MODELS:
                size = WHISPER_MODEL_SIZES.get(model_id, "?")
                item = rumps.MenuItem(f"{label} · {size}", callback=self.change_model)
                if _dl_icon:
                    item.set_icon(str(_dl_icon), dimensions=[16, 16], template=True)
                if model_id == current_model:
                    item.state = 1
                self._model_menu_item.add(item)

        # Language selection — native submenu, stays open after clicks via NSMenuItem.setView_()
        lang_item = rumps.MenuItem(i18n.t("menu.languages"), **_icon("languages"))
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
        ai_editor_item = rumps.MenuItem(i18n.t("menu.ai_editor"), **_icon("ai-editor"), callback=self._toggle_ai_editor)
        ai_editor_item.state = 1 if self.config.get("ai_editor_enabled", False) else 0
        self.menu.add(ai_editor_item)

        # AI Editor Backend submenu
        self._ai_backend_submenu = rumps.MenuItem(i18n.t("menu.ai_backend"))
        self._ai_backend_local_item = rumps.MenuItem(i18n.t("menu.ai_local"), callback=self._on_set_ai_backend_local)
        self._ai_backend_gemini_item = rumps.MenuItem(i18n.t("menu.ai_gemini"), callback=self._on_set_ai_backend_gemini)
        self._ai_backend_submenu.add(self._ai_backend_local_item)
        self._ai_backend_submenu.add(self._ai_backend_gemini_item)
        self._ai_backend_submenu.add(None)
        self._ai_backend_submenu.add(rumps.MenuItem(i18n.t("menu.set_gemini_key"), callback=self._on_set_gemini_api_key))
        self.menu.add(self._ai_backend_submenu)
        self._update_ai_backend_submenu_state()

        self.menu.add(rumps.MenuItem(i18n.t("menu.download_ai_model"), **_icon("download-model"), callback=self._download_ai_model))

        # Initial Prompt submenu
        self._prompt_menu_item = rumps.MenuItem(i18n.t("menu.initial_prompt"), **_icon("initial-prompt"))
        self._prompt_menu_item.add(rumps.MenuItem(i18n.t("menu.edit_terms"), callback=self._on_manage_terms))
        self._prompt_menu_item.add(rumps.MenuItem(i18n.t("menu.revert_terms"), callback=self.revert_initial_prompt))
        self._prompt_menu_item.add(None)

        # Auto-update Mode submenu (Suggest / Auto / Disabled)
        self._mode_items = {}
        mode_menu = rumps.MenuItem(i18n.t("menu.auto_update_mode"))
        for _mode_key, _mode_label in [
            ("suggest", i18n.t("menu.mode_suggest")),
            ("auto", i18n.t("menu.mode_auto")),
            ("disabled", i18n.t("menu.mode_disabled")),
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

        self._suggest_item = rumps.MenuItem(i18n.t("menu.review_suggestions"), callback=self._on_review_suggestions)
        self._prompt_menu_item.add(self._suggest_item)
        self._prompt_menu_item.add(rumps.MenuItem(i18n.t("menu.edit_replacements"), callback=self._on_edit_replacements))
        self._prompt_menu_item.add(rumps.MenuItem(i18n.t("menu.statistics"), callback=self._show_statistics_alert))
        self.menu.add(self._prompt_menu_item)
        self.update_suggest_menu_badge()

        # Phrase history
        self._last_phrases_parent = rumps.MenuItem(i18n.t("menu.last_phrases"), **_icon("last-phrases"))
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

        self.menu.add(rumps.MenuItem(i18n.t("menu.transcribe_file"), **_icon("transcribe-file"), callback=self.transcribe_audio_file))

        self.menu.add(None)  # Separator

        self.menu.add(rumps.MenuItem(i18n.t("menu.check_updates"), **_icon("check-updates"), callback=self.check_for_updates))

        # Autostart
        autostart_item = rumps.MenuItem(i18n.t("menu.launch_at_login"), **_icon("launch-at-login"), callback=self.toggle_autostart)
        autostart_item.state = 1 if is_launch_at_login_enabled() else 0
        self.menu.add(autostart_item)

        # Advanced submenu
        advanced_menu = rumps.MenuItem(i18n.t("menu.advanced"), **_icon("advanced"))
        advanced_menu.add(rumps.MenuItem(i18n.t("menu.edit_config"), callback=self.open_config))
        advanced_menu.add(rumps.MenuItem(i18n.t("menu.open_log"), callback=self.open_log_file))
        advanced_menu.add(rumps.MenuItem(i18n.t("menu.reload_config"), callback=self.reload_config))
        self.menu.add(advanced_menu)

        self.menu.add(rumps.MenuItem(i18n.t("menu.restart"), **_icon("restart"), callback=self.restart_application))
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

    def _parse_model_title(self, title: str) -> str:
        """Extract clean label from a menu item title, stripping all state decorations.

        '🟢 Turbo · ~795 MB' → 'Turbo'
        'Large v3 · ~1.5 GB' → 'Large v3'
        'Turbo · 45% ↓'      → 'Turbo'
        'Turbo ⚠ Повтор'     → 'Turbo'
        """
        t = title.strip()
        if t.startswith(_ICON_CACHED):
            t = t[len(_ICON_CACHED):].strip()
        t = t.split(" · ", 1)[0]   # cut at first " · " (size, percent, etc.)
        t = t.split(" ⚠", 1)[0]    # cut error suffix
        return t.strip()

    def _start_model_cache_check(self) -> None:
        """Start a daemon thread that checks HuggingFace cache for all Whisper models."""
        t = threading.Thread(target=self._update_model_cache_indicators, daemon=True)
        t.start()

    def _get_model_bytes_on_disk(self, model_id: str) -> int:
        """Return bytes present on disk for a model — both complete and partial blobs.

        HF Hub stores incomplete downloads as '<sha256>.incomplete' files alongside
        finished blobs in the model's blobs/ directory.  Summing all of them gives an
        accurate picture of how much has been transferred so far.
        """
        import pathlib
        cache_dir = os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface/hub")
        blobs_dir = pathlib.Path(cache_dir) / ("models--" + model_id.replace("/", "--")) / "blobs"
        if not blobs_dir.exists():
            return 0
        try:
            return sum(f.stat().st_size for f in blobs_dir.iterdir() if f.is_file())
        except Exception:
            return 0

    def _update_model_cache_indicators(self) -> None:
        """Check each Whisper model against the local HF cache and update menu icons.

        For each model:
        - fully cached   → green icon, no state entry
        - partially on disk (≥1 MB)  → "partial" state with % in menu title
        - nothing on disk → download icon, no state entry

        Runs in a background thread; schedules UI updates on the main thread.
        """
        try:
            import huggingface_hub  # type: ignore  # noqa: F401
        except ImportError:
            log_error("huggingface_hub not installed — cannot check model cache status.")
            return

        for label, model_id in WHISPER_MODELS:
            cached = self._is_whisper_model_cached(model_id)
            disk_bytes = 0 if cached else self._get_model_bytes_on_disk(model_id)

            def _apply(
                lbl: str = label,
                mid: str = model_id,
                is_cached: bool = cached,
                d_bytes: int = disk_bytes,
            ) -> None:
                try:
                    # Trust positive results; don't overwrite a known-good True with a
                    # stale False from a scan that ran just after _on_download_complete.
                    if not self._cached_models.get(mid):
                        self._cached_models[mid] = is_cached
                    # Never overwrite an active in-session download.
                    if self._download_state.get(mid) == "downloading":
                        return

                    if not is_cached and d_bytes >= 1_000_000:
                        # Partial download detected on disk — restore progress display.
                        # Only initialise if there is no fresher in-session value.
                        if self._download_state.get(mid) != "partial":
                            total = _MODEL_SIZE_BYTES.get(mid, 0)
                            pct = min(99, int(100 * d_bytes / total)) if total else 0
                            self._partial_bytes[mid] = d_bytes
                            self._download_progress[mid] = pct
                            self._download_state[mid] = "partial"

                    if self._model_row_refs:
                        self._update_model_row_view(mid)
                    else:
                        for item in self._model_menu_item.values():
                            if self._parse_model_title(item.title) == lbl:
                                new_title = self._render_model_menu_item(mid)
                                if item.title != new_title:
                                    item.title = new_title
                                if is_cached:
                                    item.set_icon(None)
                                else:
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

    def _render_model_menu_item(self, model_id: str) -> str:
        """Return the title string for a model menu item based on current state."""
        label = next((l for l, mid in WHISPER_MODELS if mid == model_id), model_id)
        size = WHISPER_MODEL_SIZES.get(model_id, "?")
        state = self._download_state.get(model_id)
        if state == "downloading":
            pct = self._download_progress.get(model_id, 0)
            return f"{label} · {pct}% ↓"
        if state == "partial":
            pct = self._download_progress.get(model_id, 0)
            return f"{label} · {pct}% ↙ продолжить"
        if state == "error":
            return f"{label} ⚠ Повтор"
        if self._cached_models.get(model_id):
            return f"{_ICON_CACHED} {label} · {size}"
        return f"{label} · {size}"

    def _refresh_model_menu_titles(self) -> None:
        """Update all model rows. Must run on main thread."""
        if self._model_row_refs:
            for _, model_id in WHISPER_MODELS:
                self._update_model_row_view(model_id)
        else:
            for label, model_id in WHISPER_MODELS:
                new_title = self._render_model_menu_item(model_id)
                for item in self._model_menu_item.values():
                    if self._parse_model_title(item.title) == label:
                        if item.title != new_title:
                            item.title = new_title
                        break

    def _on_download_progress(self, model_id: str, downloaded: int, total: int | None) -> None:
        """Called from download thread; posts a throttled menu refresh to main thread.

        downloaded — bytes transferred in the current session (starts at 0 for each new
        download, even on resume). The caller adds initial_bytes before calling so that
        this value already reflects the cumulative total across sessions.
        """
        total_ref = total or _MODEL_SIZE_BYTES.get(model_id, 0)
        pct = min(99, int(100 * downloaded / total_ref)) if total_ref else 0
        if pct == self._download_progress.get(model_id):
            return  # skip when percent hasn't changed — avoids menu thrash
        if hasattr(self.main_app, "_main_thread_queue"):
            def _apply_progress(p: int = pct, d: int = downloaded) -> None:
                self._download_progress[model_id] = p
                self._partial_bytes[model_id] = d
                self._refresh_model_menu_titles()
            self.main_app._main_thread_queue.put_nowait((_apply_progress, [], {}))

    def _preflight_download(self, model_id: str) -> tuple[bool, str | None]:
        """Check disk space before starting a download. Returns (ok, error_message)."""
        import shutil
        cache_dir = os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface/hub")
        os.makedirs(cache_dir, exist_ok=True)
        needed = _MODEL_SIZE_BYTES.get(model_id, 0)
        if needed:
            try:
                free = shutil.disk_usage(cache_dir).free
                if free < needed * 1.2:
                    free_gb = free / 1e9
                    need_gb = needed * 1.2 / 1e9
                    return False, i18n.t(
                        "dialog.download_no_space",
                        free_gb=f"{free_gb:.1f}",
                        need_gb=f"{need_gb:.1f}",
                    )
            except Exception:
                pass  # disk_usage failed — proceed optimistically
        return True, None

    # ------------------------------------------------------------------
    # Model row view helpers
    # ------------------------------------------------------------------

    def _get_model_left_nsimage(
        self, model_id: str, is_active: bool, is_cached: bool, state: str | None
    ):
        """Return the appropriate NSImage for the model row's left icon slot."""
        try:
            from AppKit import NSImage, NSImageSymbolConfiguration, NSColor  # type: ignore
            if is_cached:
                symbol = "checkmark.circle.fill" if is_active else "circle.fill"
                img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(symbol, None)
                if img:
                    cfg = NSImageSymbolConfiguration.configurationWithHierarchicalColor_(
                        NSColor.systemGreenColor()
                    )
                    return img.imageWithSymbolConfiguration_(cfg)
            p = get_menu_item_icon_path("download-model")
            if p:
                from AppKit import NSImage as _NSImage2  # type: ignore
                img = _NSImage2.alloc().initWithContentsOfFile_(str(p))
                if img:
                    img.setTemplate_(True)  # renders white in menu context, like template icons
                return img
        except Exception:
            pass
        return None

    def _update_model_row_view(self, model_id: str) -> None:
        """Refresh label, icon, and trash-btn visibility for one custom model row.
        Must run on the main thread.
        """
        refs = self._model_row_refs.get(model_id)
        if not refs:
            return
        label_name = next((l for l, mid in WHISPER_MODELS if mid == model_id), model_id)
        is_cached = self._cached_models.get(model_id, False)
        is_active = self.config.get("model_name") == model_id
        state = self._download_state.get(model_id)
        pct = self._download_progress.get(model_id, 0)

        if state == "downloading":
            text = f"{label_name} · {pct}% ↓"
        elif state == "partial":
            text = f"{label_name} · {pct}% ↙ продолжить"
        elif state == "error":
            text = f"{label_name} ⚠ Повтор"
        else:
            text = f"{label_name} · {WHISPER_MODEL_SIZES.get(model_id, '?')}"

        refs["label"].setStringValue_(text)
        refs["icon_view"].setImage_(
            self._get_model_left_nsimage(model_id, is_active, is_cached, state)
        )
        refs["trash_btn"].setHidden_(not is_cached)
        refs["ns_item"].setState_(1 if is_active else 0)

    def _do_switch_model(self, model_id: str, label: str) -> None:
        """Core model-switch logic. Called from row delegate and change_model fallback."""
        if self._download_state.get(model_id) == "downloading":
            if self._download_panel:
                self._download_panel.bring_to_front()
            return

        if self._download_state.get(model_id) in ("error", "partial"):
            self._download_state.pop(model_id, None)
            self._refresh_model_menu_titles()

        if not self._is_whisper_model_cached_fresh(model_id):
            self._prompt_whisper_model_download(label, model_id)
            return

        log_info(f"Switching model to {model_id}")
        self.main_app.update_config({"model_name": model_id})

        if self._model_row_refs:
            for mid in self._model_row_refs:
                self._update_model_row_view(mid)
        else:
            # Fallback: update rumps item states
            for item in self._model_menu_item.values():
                if hasattr(item, "state"):
                    item.state = 0
            for item in self._model_menu_item.values():
                if self._parse_model_title(getattr(item, "title", "")) == label:
                    item.state = 1
                    break

    def change_model(self, sender):
        """Fallback callback used when custom row views are unavailable."""
        clean_label = self._parse_model_title(sender.title)
        model_id = {lbl: mid for lbl, mid in WHISPER_MODELS}.get(clean_label)
        if not model_id:
            log_error(f"change_model: unknown label '{clean_label}'")
            return
        self._do_switch_model(model_id, clean_label)

    def _is_whisper_model_cached(self, model_id: str) -> bool:
        """Return True if the model is fully present in the local HuggingFace cache.

        A model is considered cached only when its snapshot directory contains at least
        one weight file (.npz, .safetensors, .bin, .pt).  A snapshot with only metadata
        (config.json, README) means the download was interrupted before weights arrived.
        """
        try:
            from huggingface_hub import snapshot_download  # type: ignore
            import pathlib
            local_path = snapshot_download(repo_id=model_id, local_files_only=True)
            _WEIGHT_SUFFIXES = {".npz", ".safetensors", ".bin", ".pt", ".gguf"}
            return any(
                f.suffix in _WEIGHT_SUFFIXES
                for f in pathlib.Path(local_path).iterdir()
            )
        except Exception:
            return False

    def _is_whisper_model_cached_fresh(self, model_id: str) -> bool:
        """Return True if the model is in the local HF cache.

        Always reads from the in-memory _cached_models dict — O(1), no disk I/O.
        If the background scan hasn't reached this model yet, returns False
        (treated as uncached), which will show the download prompt.  The background
        scan updates _cached_models when it finishes; re-opening the submenu then
        shows the correct state.  We never fall back to a synchronous disk check here
        because this method is called on the main thread from an ObjC action, and a
        blocking snapshot_download() call would freeze AppKit's event loop.
        """
        return self._cached_models.get(model_id, False)

    def _prompt_whisper_model_download(self, label: str, model_id: str) -> None:
        """Show an NSAlert offering to download a Whisper model that isn't cached."""
        try:
            from AppKit import NSAlert, NSInformationalAlertStyle  # type: ignore
        except ImportError:
            self.main_app.notify(
                i18n.t("notify.model_not_downloaded_title", label=label),
                i18n.t("notify.model_not_downloaded_body", model_id=model_id),
            )
            return

        import shutil as _shutil
        size_str = WHISPER_MODEL_SIZES.get(model_id, "?")
        total_bytes = _MODEL_SIZE_BYTES.get(model_id, 0)
        partial_bytes = self._partial_bytes.get(model_id, 0)
        is_partial = partial_bytes >= 1_000_000

        cache_dir = os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface/hub")
        try:
            free_gb = _shutil.disk_usage(cache_dir).free / 1e9
            disk_info = i18n.t("dialog.download_disk_free", gb=f"{free_gb:.0f}")
        except Exception:
            disk_info = ""

        if is_partial and total_bytes:
            done_pct = min(99, int(100 * partial_bytes / total_bytes))
            remaining_mb = max(0, (total_bytes - partial_bytes)) / (1024 * 1024)
            informative = i18n.t("dialog.download_progress_body", done_pct=done_pct, remaining_mb=f"{remaining_mb:.0f}")
        else:
            informative = i18n.t("dialog.download_size_body", size_str=size_str)
        if disk_info:
            informative += f" · {disk_info}"
        informative += i18n.t("dialog.download_info_suffix")

        alert = NSAlert.alloc().init()
        alert.setAlertStyle_(NSInformationalAlertStyle)
        if is_partial:
            alert.setMessageText_(i18n.t("dialog.download_continue_title", label=label))
        else:
            alert.setMessageText_(i18n.t("dialog.download_new_title", label=label))
        alert.setInformativeText_(informative)
        alert.addButtonWithTitle_(i18n.t("btn.download_continue") if is_partial else i18n.t("btn.download"))
        alert.addButtonWithTitle_(i18n.t("btn.cancel"))

        response = alert.runModal()
        # First button (Download) = 1000
        if response != 1000:
            return

        ok, err_msg = self._preflight_download(model_id)
        if not ok:
            from AppKit import NSCriticalAlertStyle  # type: ignore
            err_alert = NSAlert.alloc().init()
            err_alert.setAlertStyle_(NSCriticalAlertStyle)
            err_alert.setMessageText_(i18n.t("dialog.download_error_title"))
            err_alert.setInformativeText_(err_msg or "")
            err_alert.addButtonWithTitle_(i18n.t("btn.ok"))
            err_alert.runModal()
            return

        log_info(f"_prompt_whisper_model_download: preflight OK, queuing _start for {model_id}")
        # Queue panel creation on the main-thread drain cycle — avoids showing a new
        # NSPanel while still inside the menu callback (AppKit event-handling context).
        if hasattr(self.main_app, "_main_thread_queue"):
            self.main_app._main_thread_queue.put_nowait(
                (self._start_whisper_model_download, [label, model_id], {})
            )
        else:
            self._start_whisper_model_download(label, model_id)

    def _start_whisper_model_download(self, label: str, model_id: str) -> None:
        """Start an in-app download using ModelDownloader + ModelDownloadPanel.

        On completion calls _on_download_complete() directly — no polling, no restart needed.
        Only one download runs at a time.
        """
        log_info(f"_start_whisper_model_download: entry for {model_id}")
        from .model_downloader import ModelDownloader
        from .model_download_panel import ModelDownloadPanel

        # Iterate over the constant WHISPER_MODELS list, not the mutable _download_state dict,
        # to avoid RuntimeError if the download thread mutates _download_state concurrently.
        if any(self._download_state.get(mid) == "downloading" for _, mid in WHISPER_MODELS):
            self.main_app.notify(
                i18n.t("notify.download_in_progress_title"),
                i18n.t("notify.download_in_progress_body"),
            )
            return

        self._download_state[model_id] = "downloading"
        self._refresh_model_menu_titles()

        total_size = _MODEL_SIZE_BYTES.get(model_id, 0)
        # Bytes already downloaded in a previous session (saved when user cancelled).
        # Added to the session counter so progress display is cumulative across resumes.
        initial_bytes = self._partial_bytes.get(model_id, 0)
        log_info(
            f"_start_whisper_model_download: total={total_size}, initial_bytes={initial_bytes}"
        )
        panel = ModelDownloadPanel()
        self._download_panel = panel
        downloader = ModelDownloader()
        self._downloader = downloader

        q = self.main_app._main_thread_queue
        _last_panel_put: list[float] = [0.0]

        def on_progress(session_bytes: int, total: int | None) -> None:
            cumulative = initial_bytes + session_bytes
            self._on_download_progress(model_id, cumulative, total)
            import time as _time
            now = _time.monotonic()
            if now - _last_panel_put[0] >= 0.2:
                _last_panel_put[0] = now
                q.put_nowait((panel.update_progress, [cumulative, total or total_size], {}))

        def on_done() -> None:
            log_info(f"Download complete: {model_id}")
            self._partial_bytes.pop(model_id, None)
            q.put_nowait((panel.finish, [], {"success": True}))
            q.put_nowait((self._on_download_complete, [model_id, label], {}))

        def on_error(err: str) -> None:
            log_error(f"Download error {model_id}: {err}")
            # Mutations of _download_state/_download_progress go through the main-thread
            # queue so they never race with _start_whisper_model_download's guard check.
            def _apply_error() -> None:
                self._download_state[model_id] = "error"
                self._download_progress.pop(model_id, None)
                self._refresh_model_menu_titles()
                panel.finish(success=False, error=err)
                try:
                    from AppKit import NSAlert, NSCriticalAlertStyle  # type: ignore
                    alert = NSAlert.alloc().init()
                    alert.setAlertStyle_(NSCriticalAlertStyle)
                    alert.setMessageText_(i18n.t("dialog.download_error_title", label=label))
                    alert.setInformativeText_(err[:300])
                    alert.addButtonWithTitle_(i18n.t("btn.ok"))
                    alert.runModal()
                except Exception:
                    self.main_app.notify(i18n.t("notify.model_download_error", label=label), err[:120])
            q.put_nowait((_apply_error, [], {}))

        def on_cancelled() -> None:
            log_info(f"Download cancelled: {model_id}")
            def _apply_cancel() -> None:
                # Keep _download_progress so the menu shows the partial percentage.
                self._download_state[model_id] = "partial"
                self._refresh_model_menu_titles()
                panel.close()
            q.put_nowait((_apply_cancel, [], {}))

        panel.show(label, model_id, total_size, cancel_callback=downloader.cancel)
        # If resuming a partial download, initialise the panel at the saved progress position.
        if initial_bytes > 0 and total_size > 0:
            panel.update_progress(initial_bytes, total_size)
        log_info("_start_whisper_model_download: panel shown, starting downloader")
        downloader.start(model_id, total_size, on_progress, on_done, on_error, on_cancelled)
        log_info(f"Whisper model download started internally: {model_id}")

    def _on_download_complete(self, model_id: str, label: str) -> None:
        """Called on the main thread after a Whisper model download finishes successfully."""
        log_info(f"Whisper model download complete, activating: {model_id}")

        self._download_state.pop(model_id, None)
        self._download_progress.pop(model_id, None)
        self._cached_models[model_id] = True

        # Switch active model — no restart needed
        self.main_app.update_config({"model_name": model_id})

        # Refresh all rows (icon, trash btn, checkmark)
        self._refresh_model_menu_titles()

        # Trigger full cache rescan to update any other models' icons
        self._start_model_cache_check()

        if not self._model_row_refs:
            # Fallback: update rumps item checkmarks
            for item in self._model_menu_item.values():
                if hasattr(item, "state"):
                    item.state = 0
                if self._parse_model_title(getattr(item, "title", "")) == label:
                    item.state = 1

        self.main_app.notify(
            i18n.t("notify.model_ready_title", label=label),
            i18n.t("notify.model_ready_body"),
        )

    def _confirm_and_delete_model(self, label: str, model_id: str) -> None:
        """Show a confirmation alert, then delete the model from the HF disk cache."""
        try:
            from AppKit import NSAlert, NSWarningAlertStyle  # type: ignore
            alert = NSAlert.alloc().init()
            alert.setAlertStyle_(NSWarningAlertStyle)
            alert.setMessageText_(i18n.t("dialog.delete_model_title", label=label))
            alert.setInformativeText_(i18n.t("dialog.delete_model_body", size=WHISPER_MODEL_SIZES.get(model_id, "?")))
            alert.addButtonWithTitle_(i18n.t("btn.delete"))
            alert.addButtonWithTitle_(i18n.t("btn.cancel"))
            if alert.runModal() != 1000:
                return
        except ImportError:
            pass

        import pathlib
        import shutil

        cache_dir = os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface/hub")
        model_dir = pathlib.Path(cache_dir) / ("models--" + model_id.replace("/", "--"))

        try:
            if model_dir.exists():
                shutil.rmtree(model_dir)
            log_info(f"Deleted model cache: {model_dir}")
        except OSError as exc:
            log_error(f"Failed to delete model {model_id}: {exc}")
            try:
                from AppKit import NSAlert, NSCriticalAlertStyle  # type: ignore
                err = NSAlert.alloc().init()
                err.setAlertStyle_(NSCriticalAlertStyle)
                err.setMessageText_(i18n.t("dialog.delete_model_error_title", label=label))
                err.setInformativeText_(str(exc)[:300])
                err.addButtonWithTitle_(i18n.t("btn.ok"))
                err.runModal()
            except ImportError:
                pass
            return

        # Update in-memory state
        self._cached_models[model_id] = False
        self._download_state.pop(model_id, None)
        self._download_progress.pop(model_id, None)
        self._partial_bytes.pop(model_id, None)

        # Refresh row view (hides trash btn, restores download icon)
        self._refresh_model_menu_titles()
        # Also trigger full rescan so other models' icons are consistent
        self._start_model_cache_check()

        # If the active model was deleted, fall back to the best available cached model.
        # _RECOMMENDED_MODEL is preferred but must itself be cached; if it isn't, pick
        # any other cached model in WHISPER_MODELS order.
        current = self.config.get("model_name", "")
        if current == model_id:
            fallback_id = next(
                (
                    mid for mid in
                    [_RECOMMENDED_MODEL, *(m for _, m in WHISPER_MODELS)]
                    if mid != model_id and self._cached_models.get(mid)
                ),
                None,
            )
            if fallback_id:
                self.main_app.update_config({"model_name": fallback_id})
                # Refresh again so the new active model gets its checkmark
                self._refresh_model_menu_titles()
                fallback_label = next((l for l, mid in WHISPER_MODELS if mid == fallback_id), "")
                self.main_app.notify(
                    i18n.t("notify.model_deleted_title", label=label),
                    i18n.t("notify.model_deleted_fallback_body", fallback=fallback_label),
                )
            else:
                self.main_app.notify(
                    i18n.t("notify.model_deleted_title", label=label),
                    i18n.t("notify.model_deleted_no_models_body"),
                )
        else:
            self.main_app.notify(
                i18n.t("notify.model_deleted_title", label=label),
                i18n.t("notify.model_deleted_freed_body", size=WHISPER_MODEL_SIZES.get(model_id, "?")),
            )

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
            write_text_atomic(prompt_path, ", ".join(_term_str(t) for t in terms_list))
        except OSError as e:
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
        parent.add(rumps.MenuItem(i18n.t("menu.history_hint"), callback=None))
        parent.add(None)

        if not phrases:
            parent.add(rumps.MenuItem(i18n.t("menu.history_empty"), callback=None))
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
            parent.add(rumps.MenuItem(i18n.t("menu.show_more"), callback=self._show_more_phrases))

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
        self.main_app.notify(i18n.t("notify.config_title"), i18n.t("notify.config_reloaded"))
        self._lang_menu_controller = None  # will be rebuilt in setup_menu()
        self.menu.clear()
        self.setup_menu()

    def _schedule_prompt_terms_editor(self, lang: str) -> None:
        """Show the terms editor on the main thread (never from an NSMenu tracking loop)."""
        lang = normalize_lang_code(lang)
        if hasattr(self.main_app, "_main_thread_queue"):
            self.main_app._main_thread_queue.put_nowait((self._open_prompt_terms_editor, [lang], {}))
        else:
            self._open_prompt_terms_editor(lang)

    def _edit_prompt_for_lang_external(self, lang: str) -> None:
        """Write ``user_terms[lang]`` to its ``.txt`` file and open it in the default editor."""
        lang = normalize_lang_code(lang)
        self._sync_prompt_file(lang)
        prompt_path = str(self._get_prompt_path(lang))
        try:
            subprocess.run(["open", "-t", prompt_path], check=False)
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

    def _open_prompt_terms_editor(self, lang: str) -> None:
        """NSPanel with editable term list (same parsing as ``initial_prompt_{lang}.txt``)."""
        if not _HAVE_PROMPT_TERMS_PANEL or _PromptTermsPanelDelegate is None:
            log_error("Prompt terms panel unavailable — opening external editor.")
            self._edit_prompt_for_lang_external(lang)
            return

        from Foundation import NSRect, NSPoint, NSSize  # type: ignore
        from AppKit import (  # type: ignore
            NSBackingStoreBuffered,
            NSButton,
            NSFont,
            NSMakeRect,
            NSPanel,
            NSScrollView,
            NSTextField,
            NSTextView,
            NSViewHeightSizable,
            NSViewMaxYMargin,
            NSViewMinYMargin,
            NSViewWidthSizable,
            NSWindowStyleMaskClosable,
            NSWindowStyleMaskResizable,
            NSWindowStyleMaskTitled,
            NSScreen,
            NSViewMaxXMargin,
        )

        lang = normalize_lang_code(lang)

        if self._prompt_terms_panel is not None:
            try:
                self._prompt_terms_panel.close()
            except Exception:
                pass
            self._prompt_terms_editor_closed()

        user_terms = self.config.get("user_terms") or {}
        terms_list = list(user_terms.get(lang, []))
        initial_text = ", ".join(_term_str(t) for t in terms_list)
        inactive_count = sum(1 for t in terms_list if isinstance(t, dict) and t.get("inactive"))

        W, H = 520.0, 440.0
        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(80.0, 80.0, W, H),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
            NSBackingStoreBuffered,
            False,
        )
        panel.setTitle_(i18n.t("dialog.whisper_terms_title", lang=lang.upper()))

        delegate = _PromptTermsPanelDelegate.alloc().init().configure(self, lang)
        panel.setDelegate_(delegate)

        content = panel.contentView()
        bounds = content.bounds()
        cw = bounds.size.width
        ch = bounds.size.height

        hint = NSTextField.wrappingLabelWithString_(i18n.t("dialog.whisper_terms_hint"))
        hint.setFrame_(NSMakeRect(12.0, ch - 12.0 - 52.0, cw - 24.0, 52.0))
        hint.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(hint)

        scroll_bottom = 70.0
        scroll_top_gap = 12.0 + 52.0 + 8.0
        scroll_h = max(120.0, ch - scroll_bottom - scroll_top_gap)
        scroll_y = scroll_bottom
        scroll_w = cw - 24.0

        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(12.0, scroll_y, scroll_w, scroll_h)
        )
        scroll.setHasVerticalScroller_(True)
        scroll.setHasHorizontalScroller_(False)
        scroll.setAutohidesScrollers_(False)
        scroll.setBorderType_(2)  # NSBezelBorder
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable | NSViewMaxYMargin)
        content_size = scroll.contentSize()
        tv_rect = NSRect(NSPoint(0, 0), NSSize(content_size.width, content_size.height))
        text_view = NSTextView.alloc().initWithFrame_(tv_rect)
        text_view.setMinSize_(NSSize(content_size.width, content_size.height))
        text_view.setMaxSize_(NSSize(1e7, 1e7))
        text_view.setVerticallyResizable_(True)
        text_view.setHorizontallyResizable_(False)
        text_view.textContainer().setWidthTracksTextView_(True)
        text_view.textContainer().setContainerSize_(NSSize(content_size.width, 1e7))
        text_view.setFont_(NSFont.monospacedSystemFontOfSize_weight_(13.0, 0.0))
        text_view.setEditable_(True)
        text_view.setSelectable_(True)
        text_view.setRichText_(False)
        text_view.setAutomaticQuoteSubstitutionEnabled_(False)
        text_view.setAutomaticDashSubstitutionEnabled_(False)
        text_view.setString_(initial_text)
        scroll.setDocumentView_(text_view)
        content.addSubview_(scroll)

        btn_y = 10.0
        btn_w = 88.0
        btn_h = 28.0
        cancel_btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(cw - 12.0 - btn_w, btn_y, btn_w, btn_h)
        )
        cancel_btn.setTitle_(i18n.t("btn.cancel"))
        cancel_btn.setTarget_(delegate)
        cancel_btn.setAction_("cancelClicked:")
        cancel_btn.setAutoresizingMask_(NSViewMinYMargin | NSViewMaxXMargin)
        content.addSubview_(cancel_btn)

        save_btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(cw - 12.0 - btn_w - 8.0 - btn_w, btn_y, btn_w, btn_h)
        )
        save_btn.setTitle_(i18n.t("btn.save"))
        save_btn.setKeyEquivalent_("\r")
        save_btn.setTarget_(delegate)
        save_btn.setAction_("saveClicked:")
        save_btn.setAutoresizingMask_(NSViewMinYMargin | NSViewMaxXMargin)
        content.addSubview_(save_btn)

        del_btn_w = 140.0
        delete_btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(12.0, btn_y, del_btn_w, btn_h)
        )
        delete_btn.setTitle_(i18n.t("btn.delete_inactive"))
        delete_btn.setTarget_(delegate)
        delete_btn.setAction_("deleteInactiveClicked:")
        delete_btn.setAutoresizingMask_(NSViewMinYMargin | NSViewMaxXMargin)
        delete_btn.setHidden_(inactive_count == 0)
        content.addSubview_(delete_btn)

        stats_label = NSTextField.labelWithString_(self._terms_stats_text(lang))
        stats_label.setFrame_(NSMakeRect(12.0, btn_y + btn_h + 4.0, cw - 24.0, 18.0))
        stats_label.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        from AppKit import NSFont as _NSFont  # type: ignore
        stats_label.setFont_(_NSFont.systemFontOfSize_(11.0))
        content.addSubview_(stats_label)

        vf = NSScreen.mainScreen().visibleFrame()
        pf = panel.frame()
        cx = vf.origin.x + max(0.0, (vf.size.width - pf.size.width) / 2.0)
        cy = vf.origin.y + max(0.0, (vf.size.height - pf.size.height) / 2.0)
        panel.setFrameOrigin_((cx, cy))

        self._prompt_terms_panel = panel
        self._prompt_terms_text_view = text_view
        self._prompt_terms_delegate = delegate
        self._prompt_terms_stats_label = stats_label
        self._prompt_terms_delete_btn = delete_btn
        panel.orderFrontRegardless()

    def _prompt_terms_editor_save(self, lang: str) -> None:
        tv = self._prompt_terms_text_view
        if tv is None:
            return
        raw = tv.string()
        if not isinstance(raw, str):
            raw = str(raw)
        lang = normalize_lang_code(lang)
        changed = self._merge_prompt_terms_text_for_lang(lang, raw, allow_empty=True)
        if changed:
            self.save_config()
            self.main_app.load_config_data(self.config)
            log_info(f"Initial prompt terms updated from in-app editor for {lang.upper()}.")
            self.main_app.notify(i18n.t("notify.prompt_updated_title"), i18n.t("notify.prompt_updated_body", lang=lang.upper()))
        self._sync_prompt_file(lang)
        prompt_path = self._get_prompt_path(lang)
        try:
            self._prompt_mtimes[lang] = prompt_path.stat().st_mtime
        except OSError:
            pass
        if self._prompt_terms_panel is not None:
            self._prompt_terms_panel.close()

    def _prompt_terms_editor_cancel(self) -> None:
        if self._prompt_terms_panel is not None:
            self._prompt_terms_panel.close()

    def _prompt_terms_editor_delete_inactive(self) -> None:
        lang = self._prompt_terms_delegate._lang if self._prompt_terms_delegate else None
        if not lang:
            return
        self._clear_inactive_terms()
        lang_norm = normalize_lang_code(lang)
        if self._prompt_terms_text_view is not None:
            user_terms = self.config.get("user_terms") or {}
            terms_list = list(user_terms.get(lang_norm, []))
            self._prompt_terms_text_view.setString_(", ".join(_term_str(t) for t in terms_list))
        if self._prompt_terms_stats_label is not None:
            self._prompt_terms_stats_label.setStringValue_(self._terms_stats_text(lang_norm))
        if self._prompt_terms_delete_btn is not None:
            self._prompt_terms_delete_btn.setHidden_(True)

    def _terms_stats_text(self, lang: str) -> str:
        user_terms = self.config.get("user_terms") or {}
        terms_list = list(user_terms.get(normalize_lang_code(lang), []))
        total = len(terms_list)
        inactive = sum(1 for t in terms_list if isinstance(t, dict) and t.get("inactive"))
        by_src: dict[str, int] = {}
        for t in terms_list:
            src = t.get("source", "manual") if isinstance(t, dict) else "manual"
            by_src[src] = by_src.get(src, 0) + 1
        parts = [f"{total} terms"]
        details = [f"{by_src[k]} {k}" for k in ("manual", "correction", "auto") if by_src.get(k)]
        if inactive:
            details.append(f"{inactive} inactive")
        if details:
            parts.append("(" + " · ".join(details) + ")")
        return " ".join(parts)

    def _prompt_terms_editor_closed(self) -> None:
        self._prompt_terms_panel = None
        self._prompt_terms_text_view = None
        self._prompt_terms_delegate = None
        self._prompt_terms_stats_label = None
        self._prompt_terms_delete_btn = None

    def _sync_prompt_file(self, lang: str) -> None:
        """Write current user_terms[lang] to its .txt file and update the mtime tracker."""
        lang = normalize_lang_code(lang)
        user_terms = self.config.get("user_terms") or {}
        terms_list = list(user_terms.get(lang, []))
        prompt_path = self._get_prompt_path(lang)
        try:
            write_text_atomic(prompt_path, ", ".join(_term_str(t) for t in terms_list))
            self._prompt_mtimes[lang] = prompt_path.stat().st_mtime
        except OSError as exc:
            log_error(f"Failed to sync prompt file for {lang}: {exc}")

    def revert_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Swap primary-language user_terms with prompt_snapshots (one-step undo)."""
        self._revert_for_lang(get_primary_language(self.config))

    def _revert_for_lang(self, lang: str) -> None:
        """Swap user_terms[lang] with prompt_snapshots[lang] (one-step undo)."""
        lang = normalize_lang_code(lang)
        snapshots = dict(self.config.get("prompt_snapshots", {}))
        prev_terms = snapshots.get(lang)

        if not prev_terms:
            self.main_app.notify(i18n.t("notify.settings_title"), i18n.t("notify.prompt_no_prev", lang=lang.upper()))
            return

        user_terms = dict(self.config.get("user_terms") or {})
        current_terms = list(user_terms.get(lang, []))

        # Snapshots may be list[str] (legacy) or list[dict] (v5); normalise to list[dict].
        from datetime import datetime, timezone
        now_iso = datetime.now(timezone.utc).isoformat()
        if prev_terms and isinstance(prev_terms[0], str):
            reverted_items = [
                {"term": t, "source": "manual", "added_at": now_iso,
                 "last_seen": now_iso, "use_count": 0}
                for t in prev_terms
            ]
        else:
            reverted_items = list(prev_terms)

        snapshots[lang] = current_terms
        user_terms[lang] = reverted_items

        self.config["user_terms"] = user_terms
        self.config["prompt_snapshots"] = snapshots
        self.config["initial_prompt"] = build_initial_prompt(self.config)

        prompt_path = self._get_prompt_path(lang)
        try:
            write_text_atomic(prompt_path, ", ".join(_term_str(t) for t in reverted_items))
            self._prompt_mtimes[lang] = prompt_path.stat().st_mtime
        except OSError as exc:
            log_error(f"Failed to write reverted prompt file for {lang}: {exc}")

        self.save_config()
        self.main_app.load_config_data(self.config)
        self.main_app.notify(i18n.t("notify.settings_title"), i18n.t("notify.prompt_restored", lang=lang.upper()))

    def _on_manage_terms(self, _) -> None:
        """Open TermsPanel — table view of all user_terms with delete support."""
        try:
            from .terms_panel import TermsPanel

            def on_delete(to_delete: list[tuple[str, str]]) -> None:
                user_terms = self.config.get("user_terms") or {}
                n_removed = 0
                for lang, term in to_delete:
                    if lang not in user_terms:
                        continue
                    before = len(user_terms[lang])
                    user_terms[lang] = [
                        t for t in user_terms[lang]
                        if not (isinstance(t, dict) and t.get("term") == term)
                    ]
                    n_removed += before - len(user_terms[lang])
                if n_removed:
                    self.config["user_terms"] = user_terms
                    self.config["initial_prompt"] = build_initial_prompt(self.config)
                    self.save_config()
                    self.main_app.load_config_data(self.config)
                    for lang_sync in get_allowed_languages(self.config):
                        self._sync_prompt_file(lang_sync)
                    self.main_app.notify(i18n.t("notify.dict_title"), i18n.t("notify.terms_deleted", n=n_removed, term_word=i18n.plural("terms.term_word", n_removed)))

            if self._terms_panel is None:
                self._terms_panel = TermsPanel()
            self._terms_panel.show(self.config, on_delete)
        except Exception as exc:
            log_exception(f"_on_manage_terms failed: {exc}")

    def _on_edit_replacements(self, _) -> None:
        """Open panel to edit manual pairs and remove auto pairs from corrections index."""
        try:
            langs = get_allowed_languages(self.config)
            rows = list_replacement_rows_for_ui(self.config, langs)
            initial_auto = {
                (r["bucket"], r["from"], r["to"])
                for r in rows
                if r.get("source") == "auto" and r.get("bucket") in ("latin", "cyrillic")
            }

            def commit(final_rows: list[dict]) -> None:
                final_auto = {
                    (r["bucket"], r["from"], r["to"])
                    for r in final_rows
                    if r.get("source") == "auto" and r.get("bucket") in ("latin", "cyrillic")
                }
                for bucket, fr, to in initial_auto - final_auto:
                    remove_replacement_pair_from_index(str(bucket), fr, to)
                now_iso = datetime.now(timezone.utc).isoformat()
                manual_out: list[dict] = []
                seen_m: set[tuple[str, str]] = set()
                for r in final_rows:
                    if r.get("source") != "manual":
                        continue
                    left = normalize_replacement_side(str(r.get("from", "")))
                    right = normalize_replacement_side(str(r.get("to", "")))
                    if not left or not right:
                        continue
                    fk = (canonical_term_key(left), canonical_term_key(right))
                    if fk in seen_m:
                        continue
                    seen_m.add(fk)
                    at = r.get("added_at")
                    entry = {"from": left, "to": right}
                    if isinstance(at, str) and at.strip():
                        entry["added_at"] = at.strip()
                    else:
                        entry["added_at"] = now_iso
                    manual_out.append(entry)
                self.config["manual_replacements"] = manual_out
                self.save_config()
                self.main_app.load_config_data(self.config)
                self.main_app.notify(i18n.t("notify.settings_title"), i18n.t("notify.replacements_saved"))

            self._replacements_panel = ReplacementsPanel()
            self._replacements_panel.show(rows, commit)
        except Exception as exc:
            log_exception(f"_on_edit_replacements failed: {exc}")

    def _show_statistics_alert(self, _) -> None:
        """Show compact dictionary/quality metrics in an NSAlert."""
        try:
            from AppKit import NSAlert

            snapshot = None
            app = self.main_app
            if app is not None and hasattr(app, "get_metrics_snapshot"):
                snapshot = app.get_metrics_snapshot(force=True)
            if not snapshot:
                self.main_app.notify(i18n.t("stats.title"), i18n.t("notify.stats_no_data"))
                return

            def _fmt_pct(value: float | None) -> str:
                if not isinstance(value, (int, float)):
                    return "n/a"
                return f"{value * 100:.1f}%"

            def _fmt_delta(delta: float | None, positive_good: bool) -> str:
                if not isinstance(delta, (int, float)):
                    return "n/a"
                sign = "↑" if delta > 0 else "↓" if delta < 0 else "→"
                quality = "good" if (delta > 0 and positive_good) or (delta < 0 and not positive_good) else "bad"
                if abs(delta) < 1e-9:
                    quality = "neutral"
                return f"{sign} {delta * 100:+.1f}pp ({quality})"

            edit = snapshot.get("edit_score_avg")
            hit = snapshot.get("hit_rate")
            edit_delta = (snapshot.get("edit_score_trend") or {}).get("delta")
            hit_delta = (snapshot.get("hit_rate_trend") or {}).get("delta")

            failed_pairs = snapshot.get("failed_pairs") or []
            top_failed = failed_pairs[:5]

            # B5: effectiveness card — top helpers + dead weight
            from pathlib import Path as _Path
            _dataset_path = _Path(_DEFAULT_DATASET_PATH)
            helpers = top_helping_terms(_dataset_path, limit=5)
            dead = dead_weight_terms(self.config, days=30)

            lines = [
                i18n.t("stats.performance_header", n=snapshot.get("window_size", 100)),
                "",
                f"{i18n.t('stats.edit_label'):<35} {_fmt_pct(edit)}   {_fmt_delta(edit_delta, positive_good=False)}",
                f"{i18n.t('stats.hit_rate_label'):<35} {_fmt_pct(hit)}   {_fmt_delta(hit_delta, positive_good=True)}",
                (
                    f"{i18n.t('stats.active_terms_label'):<35}"
                    f"{snapshot.get('active_terms_count', 0)} "
                    f"({snapshot.get('manual_terms_count', 0)} manual / "
                    f"{snapshot.get('auto_terms_count', 0)} auto / "
                    f"{snapshot.get('correction_terms_count', 0)} correction)"
                ),
                (
                    f"{i18n.t('stats.acceptance_rate_label'):<35}"
                    f"{_fmt_pct(snapshot.get('acceptance_rate'))} "
                    f"(accepted={snapshot.get('accepted_total', 0)}, rejected={snapshot.get('rejected_total', 0)})"
                ),
                (
                    f"{i18n.t('stats.prompt_util_label'):<35}"
                    f"{_fmt_pct(snapshot.get('prompt_utilisation'))} "
                    f"({snapshot.get('prompt_tokens_used', 0)} of {snapshot.get('prompt_tokens_max', 0)} tokens)"
                ),
                "",
                i18n.t("stats.inactive_clean", n=snapshot.get("inactive_terms_count", 0)),
            ]

            # Top helpers section
            lines += ["", i18n.t("stats.top_helpers_header")]
            if helpers:
                for h in helpers:
                    pct = f"{h['recognition_rate'] * 100:.0f}%"
                    lines.append(f"  {h['term']:<18} {pct:>5}  ({h['n_raw']}/{h['n_final']})")
            else:
                lines.append(i18n.t("stats.top_helpers_empty"))

            # Dead weight section
            if dead:
                lines += ["", i18n.t("stats.dead_weight_header", n=len(dead))]
                for d in dead[:5]:
                    lines.append(f"  [{d['lang'].upper()}] {d['term']:<16} ({d['age_days']}д)")
                if len(dead) > 5:
                    lines.append(i18n.t("stats.dead_weight_more", n=len(dead) - 5))

            # Failed pairs section
            if top_failed:
                lines += [
                    "",
                    i18n.t("stats.failed_pairs_header"),
                ]
                for fp in top_failed:
                    already = any(
                        r.get("from", "").lower() == fp["from"].lower()
                        and r.get("to", "").lower() == fp["to"].lower()
                        for r in (self.config.get("manual_replacements") or [])
                    )
                    mark = " ✓" if already else ""
                    lines.append(f'  "{fp["from"]}" -> "{fp["to"]}" ({fp["count"]}x){mark}')

            alert = NSAlert.alloc().init()
            alert.setMessageText_(i18n.t("stats.title"))
            alert.setInformativeText_("\n".join(lines))
            button_actions: list[str] = []
            alert.addButtonWithTitle_(i18n.t("btn.ok"))
            button_actions.append("ok")
            alert.addButtonWithTitle_(i18n.t("stats.btn_history"))
            button_actions.append("history")
            if dead:
                alert.addButtonWithTitle_(i18n.t("stats.btn_delete_dead", n=len(dead)))
                button_actions.append("delete_dead")
            if top_failed:
                alert.addButtonWithTitle_(i18n.t("stats.btn_replacements"))
                button_actions.append("replacements")
            result = alert.runModal()
            action_idx = result - 1000
            action = button_actions[action_idx] if 0 <= action_idx < len(button_actions) else "ok"
            if action == "history":
                subprocess.run(["open", str(get_metrics_history_path())], check=False)
            elif action == "delete_dead":
                self._delete_dead_weight_terms(dead)
            elif action == "replacements":
                self._on_edit_replacements(None)
        except Exception as exc:
            log_exception(f"_show_statistics_alert failed: {exc}")

    def _delete_dead_weight_terms(self, dead: list[dict]) -> None:
        """Remove dead-weight terms (use_count=0, >30 days old) from user_terms."""
        user_terms = self.config.get("user_terms") or {}
        n_removed = 0
        for entry in dead:
            lang = entry["lang"]
            term = entry["term"]
            if lang not in user_terms:
                continue
            before = len(user_terms[lang])
            user_terms[lang] = [
                t for t in user_terms[lang]
                if not (isinstance(t, dict) and t.get("term") == term and not t.get("use_count", 0))
            ]
            n_removed += before - len(user_terms[lang])
        if n_removed:
            self.config["user_terms"] = user_terms
            self.config["initial_prompt"] = build_initial_prompt(self.config)
            self.save_config()
            self.main_app.load_config_data(self.config)
            for lang in get_allowed_languages(self.config):
                self._sync_prompt_file(lang)
            self.main_app.notify(i18n.t("notify.dict_title"), i18n.t("notify.terms_removed_dead", n=n_removed))

    def _clear_inactive_terms(self) -> None:
        """Permanently remove all inactive terms from user_terms."""
        user_terms = self.config.get("user_terms") or {}
        removed = 0
        for lang, terms in user_terms.items():
            before = len(terms)
            user_terms[lang] = [t for t in terms if not (isinstance(t, dict) and t.get("inactive"))]
            removed += before - len(user_terms[lang])
        self.config["user_terms"] = user_terms
        self.config["initial_prompt"] = build_initial_prompt(self.config)
        self.save_config()
        self.main_app.load_config_data(self.config)
        if removed > 0:
            self.main_app.notify(i18n.t("notify.dict_title"), i18n.t("notify.terms_removed_inactive", n=removed))

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
        mode_label = {
            "suggest": i18n.t("menu.mode_suggest"),
            "auto": i18n.t("menu.mode_auto"),
            "disabled": i18n.t("menu.mode_disabled"),
        }.get(mode, mode)
        self.main_app.notify(i18n.t("notify.settings_title"), i18n.t("notify.update_mode_body", mode=mode_label))

    def transcribe_audio_file(self, _: rumps.MenuItem) -> None:
        """Opens a file selection dialog and starts file transcription."""
        if self.main_app.is_recording or self.main_app.is_processing:
            self.main_app.notify(i18n.t("notify.busy_title"), i18n.t("notify.busy_processing"))
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
            self.main_app.notify(i18n.t("notify.record_error_title"), i18n.t("notify.file_open_error"))

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
                preview += i18n.t("dialog.suggestions_preview_more", n=total - 3)

            alert = NSAlert.alloc().init()
            alert.setMessageText_(i18n.t("suggestions.window_title"))
            alert.setInformativeText_(i18n.t("dialog.suggestions_body_detailed", total=total, preview=preview))
            alert.addButtonWithTitle_(i18n.t("btn.view"))
            alert.addButtonWithTitle_(i18n.t("btn.remind_later"))
            alert.addButtonWithTitle_(i18n.t("btn.auto_mode"))

            result = alert.runModal()  # 1000=first, 1001=second, 1002=third
            if result == 1000:
                self._schedule_open_suggestions_panel()
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
            self._schedule_open_suggestions_panel()
            return

        try:
            from .phrase_history import count_phrases
            phrase_count = count_phrases()
        except Exception:
            phrase_count = 0

        if phrase_count < 5:
            self.main_app.notify(
                i18n.t("notify.settings_title"),
                i18n.t("notify.history_too_small"),
            )
            return

        self.main_app.notify(i18n.t("notify.settings_title"), i18n.t("notify.history_analyzing"))
        self.main_app.request_prompt_analysis(on_complete=self._on_demand_analysis_done)

    def _on_demand_analysis_done(self) -> None:
        """Called on main thread after an on-demand analysis completes."""
        self.update_suggest_menu_badge()
        pending = self.config.get("pending_suggestions") or {}
        total = sum(len(v) for v in pending.values())
        if total > 0:
            self._schedule_open_suggestions_panel()
        else:
            self.main_app.notify(
                i18n.t("notify.settings_title"),
                i18n.t("notify.history_no_new_terms"),
            )

    def _schedule_open_suggestions_panel(self) -> None:
        """Open suggestions after the current modal/menu event has unwound."""
        if hasattr(self.main_app, "_main_thread_queue"):
            self.main_app._main_thread_queue.put_nowait((self._open_suggestions_panel, [], {}))
        else:
            self._open_suggestions_panel()

    def _open_suggestions_panel(self) -> None:
        """Open the SuggestionsPanel for reviewing candidates."""
        if self._suggestions_panel is None:
            log_error("SuggestionsPanel is unavailable; cannot open pending suggestions.")
            return
        pending = self.config.get("pending_suggestions") or {}
        if not pending:
            log_info("_open_suggestions_panel: no pending suggestions.")
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
                    key = canonical_term_key(item["term"])
                    if key:
                        lang_skipped[key] = current_count
                    skipped_terms[lang] = lang_skipped
                self.config["skipped_terms"] = skipped_terms

            # Remove shown items from pending (items not yet shown remain pending).
            shown_lower = {canonical_term_key(i["term"]) for i in accepted + rejected}
            new_pending: dict[str, list[dict]] = {}
            for lang, items in pending.items():
                remaining = [i for i in items if canonical_term_key(i["term"]) not in shown_lower]
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
        self.main_app.notify(i18n.t("notify.updates_title"), i18n.t("notify.latest_version"))

    def _toggle_ai_editor(self, sender) -> None:
        """Toggle the AI Editor on/off and persist the setting."""
        new_state = not (sender.state == 1)
        sender.state = 1 if new_state else 0
        self.main_app.update_config({"ai_editor_enabled": new_state})
        log_info(f"AI Editor {'enabled' if new_state else 'disabled'}.")
        if new_state:
            self.main_app.notify(i18n.t("notify.ai_editor_title"), i18n.t("notify.ai_downloading"))
        else:
            self.main_app.notify(i18n.t("notify.ai_editor_title"), i18n.t("notify.ai_disabled"))

    def _update_ai_backend_submenu_state(self) -> None:
        """Sync checkmarks on the backend submenu with current config."""
        backend = self.config.get("ai_editor_backend", "local")
        self._ai_backend_local_item.state = 1 if backend == "local" else 0
        self._ai_backend_gemini_item.state = 1 if backend == "gemini" else 0

    def _on_set_ai_backend_local(self, _) -> None:
        self.main_app.update_config({"ai_editor_backend": "local"})
        self._update_ai_backend_submenu_state()
        log_info("AI Editor backend set to: local")
        self.main_app.notify(i18n.t("notify.ai_editor_title"), i18n.t("notify.ai_backend_local"))

    def _on_set_ai_backend_gemini(self, _) -> None:
        self.main_app.update_config({"ai_editor_backend": "gemini"})
        self._update_ai_backend_submenu_state()
        log_info("AI Editor backend set to: gemini")
        self.main_app.notify(i18n.t("notify.ai_editor_title"), i18n.t("notify.ai_backend_gemini"))

    # Strict format check: "AIzaSy" + 33 base64url chars = 39 chars total
    _GEMINI_KEY_RE = __import__("re").compile(r"^AIzaSy[A-Za-z0-9_\-]{33}$")

    def _on_set_gemini_api_key(self, _) -> None:
        """Show a dialog to enter and save the Gemini API key to macOS Keychain."""
        try:
            from AppKit import NSAlert, NSSecureTextField, NSMakeRect, NSApp, NSPasteboard, NSPasteboardTypeString, NSFloatingWindowLevel  # type: ignore
            alert = NSAlert.alloc().init()
            alert.setMessageText_(i18n.t("dialog.gemini_key_title"))
            existing = get_gemini_api_key()
            hint = i18n.t("dialog.gemini_key_body_existing") if existing else i18n.t("dialog.gemini_key_body")
            alert.setInformativeText_(hint)
            alert.addButtonWithTitle_(i18n.t("btn.save"))
            alert.addButtonWithTitle_(i18n.t("btn.cancel"))

            field = NSSecureTextField.alloc().initWithFrame_(NSMakeRect(0, 0, 320, 24))
            field.setPlaceholderString_("AIzaSy…")

            # Auto-fill from clipboard only if it matches the exact Gemini key format
            pb = NSPasteboard.generalPasteboard()
            candidate = (pb.stringForType_(NSPasteboardTypeString) or "").strip()
            if self._GEMINI_KEY_RE.match(candidate):
                field.setStringValue_(candidate)

            alert.setAccessoryView_(field)
            alert.layout()  # forces NSAlert to create its window before we access it
            alert.window().setInitialFirstResponder_(field)

            # Float above other windows and activate so Cmd+V works after the user
            # switches to another app to copy the key and returns.
            alert.window().setLevel_(NSFloatingWindowLevel)
            NSApp.activateIgnoringOtherApps_(True)
            alert.window().makeKeyAndOrderFront_(None)

            result = alert.runModal()
            if result == 1000:  # "Сохранить"
                key = field.stringValue().strip()
                if key:
                    try:
                        set_gemini_api_key(key)
                        log_info("Gemini API key saved to Keychain.")
                        self.main_app.notify(i18n.t("notify.ai_editor_title"), i18n.t("notify.ai_key_saved"))
                    except Exception as save_exc:
                        log_error(f"Failed to save Gemini API key to Keychain: {save_exc}")
                        self.main_app.notify(i18n.t("notify.ai_editor_error_title"), i18n.t("notify.ai_key_error", err=str(save_exc)))
        except Exception as exc:
            log_error(f"Set Gemini API key dialog failed: {exc}")

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
            self.main_app.notify(i18n.t("notify.ai_editor_title"), i18n.t("notify.ai_download_started"))
        except Exception as e:
            log_error(f"Failed to open Terminal for download: {e}")
            self.main_app.notify(i18n.t("notify.ai_editor_title"), i18n.t("notify.ai_download_manual"))

    def toggle_autostart(self, sender):
        current_state = sender.state == 1
        new_state = not current_state
        try:
            set_launch_at_login(new_state)
            sender.state = 1 if new_state else 0
            if new_state:
                self.main_app.notify(i18n.t("notify.autostart_title"), i18n.t("notify.autostart_enabled"))
            else:
                self.main_app.notify(i18n.t("notify.autostart_title"), i18n.t("notify.autostart_disabled"))
        except Exception as e:
            log_error(f"Error toggling autostart: {e}")
            self.main_app.notify(i18n.t("notify.record_error_title"), i18n.t("notify.autostart_error"))

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
