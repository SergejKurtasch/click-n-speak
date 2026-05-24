"""language_picker.py — First-launch language selection window.

Shows an NSWindow with 6 language buttons. Detects system language
and pre-selects it. Saves the chosen primary_language to config and
calls i18n.load() before returning.

Called from main.py before the setup wizard when language_picker_done
is absent or False in config.
"""
from __future__ import annotations

from typing import Callable

from .utils import log_error, log_info, save_config_to_disk
from . import i18n

_SUPPORTED_LANGS: list[tuple[str, str, str]] = [
    ("ru", "🇷🇺", "Русский"),
    ("uk", "🇺🇦", "Українська"),
    ("en", "🇺🇸", "English"),
    ("de", "🇩🇪", "Deutsch"),
    ("fr", "🇫🇷", "Français"),
    ("es", "🇪🇸", "Español"),
]

_WIN_W = 480
_WIN_H = 340
_BTN_W = 200
_BTN_H = 52
_BTN_GAP_X = 16
_BTN_GAP_Y = 12
_HEADER_H = 56

# ObjC delegate class — created once at module level so the class name is
# registered in the ObjC runtime only once (PyObjC forbids reregistration).
# Methods must live inside the class body; post-creation assignment is silently
# ignored by the runtime.  A _picker attribute stores the owning
# _LanguagePickerWindow so ObjC callbacks can call back into Python.
_PickerDelegateClass: type | None = None


def _get_picker_delegate_class() -> type:
    global _PickerDelegateClass
    if _PickerDelegateClass is not None:
        return _PickerDelegateClass
    from objc import objc_method, lookUpClass
    NSObject = lookUpClass("NSObject")

    class _PickerDelegate(NSObject):  # type: ignore[valid-type]
        @objc_method(b"v@:@")
        def langClicked_(self, sender) -> None:
            owner = getattr(self, "_picker", None)
            if owner is not None:
                owner._on_lang_selected(str(sender.identifier()))

        @objc_method(b"v@:")
        def continueClicked_(self, _sender) -> None:
            owner = getattr(self, "_picker", None)
            if owner is not None:
                owner._on_continue()

        @objc_method(b"v@:@")
        def windowWillClose_(self, notification) -> None:
            # Fires when the user closes the window with the × button.
            # Call _finish so the setup wizard still launches.
            owner = getattr(self, "_picker", None)
            if owner is not None:
                owner._on_window_closed()

    _PickerDelegateClass = _PickerDelegate
    return _PickerDelegateClass


def _detect_system_lang() -> str:
    """Return the best matching supported language from macOS locale, or 'en'."""
    try:
        from Foundation import NSLocale
        prefs = NSLocale.preferredLanguages()
        if prefs:
            for lang_tag in prefs:
                code = str(lang_tag).split("-")[0].lower()
                if code == "ua":
                    code = "uk"
                if code in {lc for lc, _, _ in _SUPPORTED_LANGS}:
                    return code
    except Exception:
        pass
    return "en"


def show_if_needed(config: dict, on_done: Callable[[], None]) -> None:
    """Show the language picker if it has not been completed yet.

    *on_done* is called on the main thread after the user picks a language
    (or immediately if the picker is not needed).
    """
    if config.get("language_picker_done"):
        on_done()
        return

    _LanguagePickerWindow(config, on_done).show()


class _LanguagePickerWindow:
    def __init__(self, config: dict, on_done: Callable[[], None]) -> None:
        self._config = config
        self._on_done = on_done
        self._selected: str | None = _detect_system_lang()
        self._window = None
        self._continue_btn = None
        self._lang_buttons: dict[str, object] = {}
        self._finished: bool = False

    def show(self) -> None:
        try:
            from AppKit import (
                NSApplication,
                NSBackingStoreBuffered,
                NSButton,
                NSFont,
                NSMakeRect,
                NSScreen,
                NSTextField,
                NSWindow,
                NSWindowStyleMaskClosable,
                NSWindowStyleMaskTitled,
            )

            screen = NSScreen.mainScreen()
            sf = screen.visibleFrame()
            wx = sf.origin.x + (sf.size.width - _WIN_W) / 2
            wy = sf.origin.y + (sf.size.height - _WIN_H) / 2

            mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                NSMakeRect(wx, wy, _WIN_W, _WIN_H),
                mask,
                NSBackingStoreBuffered,
                False,
            )
            self._window.setTitle_("Click-n-speak")
            self._window.setReleasedWhenClosed_(False)

            content = self._window.contentView()

            # Title label (always English)
            title = NSTextField.alloc().initWithFrame_(
                NSMakeRect(0, _WIN_H - _HEADER_H, _WIN_W, _HEADER_H - 4)
            )
            title.setStringValue_("Choose your language")
            title.setEditable_(False)
            title.setBordered_(False)
            title.setDrawsBackground_(False)
            title.setAlignment_(1)  # NSTextAlignmentCenter
            title.setFont_(NSFont.boldSystemFontOfSize_(20.0))
            content.addSubview_(title)

            # Language buttons (3 columns × 2 rows)
            start_x = (_WIN_W - (2 * _BTN_W + _BTN_GAP_X)) / 2
            start_y = (_WIN_H - _HEADER_H - (2 * _BTN_H + _BTN_GAP_Y)) / 2 + 28

            # ObjC delegate — class is created once at module level;
            # _picker attribute gives the ObjC methods access to this window.
            DelegateClass = _get_picker_delegate_class()
            delegate = DelegateClass.alloc().init()
            delegate._picker = self
            self._delegate = delegate
            self._window.setDelegate_(delegate)  # needed for windowWillClose_

            for i, (code, flag, name) in enumerate(_SUPPORTED_LANGS):
                col = i % 2
                row = i // 2
                x = start_x + col * (_BTN_W + _BTN_GAP_X)
                y = start_y - row * (_BTN_H + _BTN_GAP_Y)

                btn = NSButton.alloc().initWithFrame_(
                    NSMakeRect(x, y, _BTN_W, _BTN_H)
                )
                btn.setTitle_(f"{flag}  {name}")
                btn.setBezelStyle_(2)  # NSBezelStyleRounded
                btn.setIdentifier_(code)
                btn.setTarget_(delegate)
                btn.setAction_("langClicked:")
                btn.setFont_(NSFont.systemFontOfSize_(15.0))
                content.addSubview_(btn)
                self._lang_buttons[code] = btn

            # Continue button
            cont_w, cont_h = 160, 36
            cont_x = (_WIN_W - cont_w) / 2
            cont_y = 20
            cont_btn = NSButton.alloc().initWithFrame_(
                NSMakeRect(cont_x, cont_y, cont_w, cont_h)
            )
            cont_btn.setTitle_("Continue →")
            cont_btn.setBezelStyle_(2)
            cont_btn.setKeyEquivalent_("\r")
            cont_btn.setTarget_(delegate)
            cont_btn.setAction_("continueClicked:")
            cont_btn.setFont_(NSFont.boldSystemFontOfSize_(14.0))
            content.addSubview_(cont_btn)
            self._continue_btn = cont_btn

            # Pre-select detected language
            if self._selected:
                self._highlight(self._selected)

            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
            self._window.makeKeyAndOrderFront_(None)
            self._window.orderFrontRegardless()

        except Exception as exc:
            log_error(f"LanguagePicker: failed to show window: {exc}")
            # Fallback: skip picker and proceed with default language
            self._finish("en")

    def _on_lang_selected(self, code: str) -> None:
        self._selected = code
        self._highlight(code)

    def _highlight(self, selected: str) -> None:
        try:
            for code, btn in self._lang_buttons.items():
                if code == selected:
                    btn.setKeyEquivalent_("")
                    # Use highlighted bezel to show selection
                    try:
                        btn.highlight_(True)
                    except Exception:
                        pass
                    btn.setTitle_(f"✓ {next(f+' '+n for lc,f,n in _SUPPORTED_LANGS if lc==code)}")
                else:
                    try:
                        btn.highlight_(False)
                    except Exception:
                        pass
                    btn.setTitle_(f"{next(f+' '+n for lc,f,n in _SUPPORTED_LANGS if lc==code)}")
        except Exception:
            pass

    def _on_continue(self) -> None:
        lang = self._selected or "en"
        self._finish(lang)

    def _on_window_closed(self) -> None:
        # Called by windowWillClose_ when user clicks ×.
        # The window is already closing, so skip close() and fall through to finish.
        if self._finished:
            return
        self._window = None  # prevent _finish from calling close() on a closing window
        self._finish(self._selected or "en")

    def _finish(self, lang: str) -> None:
        if self._finished:
            return
        self._finished = True
        try:
            if self._window:
                self._window.close()
                self._window = None
        except Exception:
            pass
        self._config["primary_language"] = lang
        self._config["language_picker_done"] = True
        save_config_to_disk(self._config)
        i18n.load(lang)
        log_info(f"LanguagePicker: selected language '{lang}'")
        try:
            self._on_done()
        except Exception as exc:
            log_error(f"LanguagePicker on_done callback failed: {exc}")
