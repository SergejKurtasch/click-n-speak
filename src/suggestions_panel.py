"""SuggestionsPanel — review and accept/reject vocabulary candidates."""

from typing import Callable

import objc
from AppKit import (
    NSApplication,
    NSBackingStoreBuffered,
    NSButton,
    NSButtonTypeSwitch,
    NSColor,
    NSControlStateValueOff,
    NSControlStateValueOn,
    NSFont,
    NSPoint,
    NSRect,
    NSScreen,
    NSSize,
    NSTextField,
    NSTextAlignmentRight,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSObject

from .utils import log_error, log_info

_PAGE_SIZE = 10
_WIN_W = 480
_MARGIN = 12
_BTN_H = 30
_ROW_H = 28
_LABEL_H = 36
_SHOW_MORE_BTN_H = 26
_SELECT_ROW_H = 26


class _PanelDelegate(NSObject):
    """ObjC target that handles button actions for SuggestionsPanel."""

    def init(self):
        self = objc.super(_PanelDelegate, self).init()
        self._owner = None
        return self

    @objc.python_method
    def set_owner(self, owner: "SuggestionsPanel") -> None:
        self._owner = owner

    def accept_(self, sender):
        if self._owner:
            self._owner._do_accept()

    def skip_(self, sender):
        if self._owner:
            self._owner._do_skip()

    def autoMode_(self, sender):
        if self._owner:
            self._owner._do_auto()

    def showMore_(self, sender):
        if self._owner:
            self._owner._do_show_more()

    def selectAll_(self, sender):
        if self._owner:
            self._owner._do_select_all()

    def deselectAll_(self, sender):
        if self._owner:
            self._owner._do_deselect_all()


class SuggestionsPanel:
    """Non-blocking NSWindow for reviewing auto-detected vocabulary candidates."""

    def __init__(self) -> None:
        self._window: NSWindow | None = None
        self._delegate = _PanelDelegate.alloc().init()
        self._delegate.set_owner(self)
        self._items: list[dict] = []
        self._visible_count: int = _PAGE_SIZE
        self._candidates_by_lang: dict = {}
        self._on_accept: Callable | None = None
        self._on_skip: Callable | None = None
        self._on_auto: Callable | None = None
        # Persists checkbox states across "Show more" rebuilds: term → checked
        self._checkbox_states: dict[str, bool] = {}

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def show(
        self,
        candidates_by_lang: dict[str, list[dict]],
        on_accept: Callable,
        on_skip: Callable,
        on_auto: Callable,
        _visible_count: int | None = None,
    ) -> None:
        """Show the review panel.

        candidates_by_lang: {"en": [{"term": "PCA", "count": 12}], "ru": [...]}
        on_accept(accepted, rejected) — accepted/rejected are lists of the same dicts
        on_skip()  — user wants to be reminded later
        on_auto()  — user opts into auto mode
        """
        self._candidates_by_lang = dict(candidates_by_lang)
        self._on_accept = on_accept
        self._on_skip = on_skip
        self._on_auto = on_auto
        if _visible_count is not None:
            self._visible_count = _visible_count

        # Flatten candidates sorted by count descending.
        all_items: list[dict] = []
        for lang, cands in candidates_by_lang.items():
            for c in cands:
                all_items.append({"term": c["term"], "count": c["count"],
                                  "lang": lang, "checkbox": None})
        all_items.sort(key=lambda x: -x["count"])
        self._items = all_items

        # Initialise all checkboxes to checked.
        self._checkbox_states = {item["term"]: True for item in self._items}

        self._build_window()

    def close(self) -> None:
        self._close_window()

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _close_window(self) -> None:
        if self._window:
            self._window.close()
            self._window = None
        for item in self._items:
            item["checkbox"] = None

    def _save_checkbox_states(self) -> None:
        """Snapshot current checkbox states so _build_window can restore them."""
        for item in self._items:
            cb = item.get("checkbox")
            if cb is not None:
                self._checkbox_states[item["term"]] = (cb.state() == NSControlStateValueOn)

    def _build_window(self) -> None:
        self._close_window()

        n = min(self._visible_count, len(self._items))
        has_more = len(self._items) > self._visible_count

        # Calculate window height (bottom → top):
        # MARGIN | BTN(30) | MARGIN | [show_more(26) | GAP(8)] | rows(n×28) | GAP(8)
        #        | select_row(26) | GAP(6) | label(36) | MARGIN
        y = _MARGIN
        btn_y = y
        y += _BTN_H + _MARGIN

        show_more_y = 0
        if has_more:
            show_more_y = y
            y += _SHOW_MORE_BTN_H + 8

        rows_start_y = y
        y += n * _ROW_H + 8

        select_row_y = y
        y += _SELECT_ROW_H + 6

        label_y = y
        y += _LABEL_H + _MARGIN
        window_h = y

        # Center on screen.
        screen = NSScreen.mainScreen()
        sf = screen.visibleFrame()
        wx = sf.origin.x + (sf.size.width - _WIN_W) / 2
        wy = sf.origin.y + (sf.size.height - window_h) / 2

        rect = NSRect(NSPoint(wx, wy), NSSize(_WIN_W, window_h))
        mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, mask, NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Новые термины для словаря")
        self._window.setReleasedWhenClosed_(False)

        content = self._window.contentView()

        # Description label
        desc = self._make_label(
            f"Выберите термины для словаря Whisper (из последних 100 фраз):",
            NSRect(NSPoint(_MARGIN, label_y), NSSize(_WIN_W - 2 * _MARGIN, _LABEL_H)),
            font_size=12.0,
        )
        content.addSubview_(desc)

        # "Select all" / "Deselect all" mini-buttons
        mini_w = 120
        sel_btn = self._make_button("Выбрать все", select_row_y, _MARGIN, mini_w, height=_SELECT_ROW_H)
        sel_btn.setTarget_(self._delegate)
        sel_btn.setAction_("selectAll:")
        content.addSubview_(sel_btn)

        desel_btn = self._make_button("Снять все", select_row_y, _MARGIN + mini_w + 8, mini_w, height=_SELECT_ROW_H)
        desel_btn.setTarget_(self._delegate)
        desel_btn.setAction_("deselectAll:")
        content.addSubview_(desel_btn)

        # Checkboxes with count badges — restore saved states on rebuild
        for i, item in enumerate(self._items[:n]):
            row_y = rows_start_y + i * _ROW_H
            checkbox = NSButton.alloc().initWithFrame_(
                NSRect(NSPoint(_MARGIN, row_y), NSSize(_WIN_W - 2 * _MARGIN - 90, _ROW_H - 4))
            )
            checkbox.setButtonType_(NSButtonTypeSwitch)
            checkbox.setTitle_(item["term"])
            checkbox.setFont_(NSFont.systemFontOfSize_(13.0))
            saved = self._checkbox_states.get(item["term"], True)
            checkbox.setState_(NSControlStateValueOn if saved else NSControlStateValueOff)
            content.addSubview_(checkbox)
            item["checkbox"] = checkbox

            badge = self._make_label(
                f"{item['count']}× / {item['lang'].upper()}",
                NSRect(NSPoint(_WIN_W - _MARGIN - 85, row_y), NSSize(80, _ROW_H - 4)),
                font_size=11.0,
                secondary=True,
                align_right=True,
            )
            content.addSubview_(badge)

        # "Show more" button
        if has_more:
            remaining = len(self._items) - self._visible_count
            more_count = min(_PAGE_SIZE, remaining)
            btn = NSButton.alloc().initWithFrame_(
                NSRect(NSPoint(_MARGIN, show_more_y), NSSize(190, _SHOW_MORE_BTN_H))
            )
            btn.setTitle_(f"Показать ещё {more_count}")
            btn.setTarget_(self._delegate)
            btn.setAction_("showMore:")
            btn.setBezelStyle_(2)
            content.addSubview_(btn)

        # Bottom buttons — three equal-width columns
        col_w = (_WIN_W - 2 * _MARGIN - 16) // 3

        auto_btn = self._make_button("Авто-режим", btn_y, _MARGIN, col_w)
        auto_btn.setTarget_(self._delegate)
        auto_btn.setAction_("autoMode:")
        content.addSubview_(auto_btn)

        skip_btn = self._make_button("Напомнить позже", btn_y, _MARGIN + col_w + 8, col_w)
        skip_btn.setTarget_(self._delegate)
        skip_btn.setAction_("skip:")
        skip_btn.setKeyEquivalent_("\x1b")
        content.addSubview_(skip_btn)

        accept_btn = self._make_button("Добавить выбранные", btn_y, _MARGIN + 2 * (col_w + 8), col_w)
        accept_btn.setTarget_(self._delegate)
        accept_btn.setAction_("accept:")
        accept_btn.setKeyEquivalent_("\r")
        content.addSubview_(accept_btn)

        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        self._window.makeKeyAndOrderFront_(None)

    # ------------------------------------------------------------------
    # Button actions (called by _PanelDelegate)
    # ------------------------------------------------------------------

    def _do_accept(self) -> None:
        accepted: list[dict] = []
        rejected: list[dict] = []
        n = min(self._visible_count, len(self._items))
        for item in self._items[:n]:
            cb = item.get("checkbox")
            entry = {"term": item["term"], "count": item["count"], "lang": item["lang"]}
            if cb is not None and cb.state() == NSControlStateValueOn:
                accepted.append(entry)
            else:
                rejected.append(entry)
        self._close_window()
        if self._on_accept:
            try:
                self._on_accept(accepted, rejected)
            except Exception as exc:
                log_error(f"SuggestionsPanel on_accept error: {exc}")

    def _do_skip(self) -> None:
        self._close_window()
        if self._on_skip:
            try:
                self._on_skip()
            except Exception as exc:
                log_error(f"SuggestionsPanel on_skip error: {exc}")

    def _do_auto(self) -> None:
        self._close_window()
        if self._on_auto:
            try:
                self._on_auto()
            except Exception as exc:
                log_error(f"SuggestionsPanel on_auto error: {exc}")

    def _do_show_more(self) -> None:
        self._save_checkbox_states()
        self._visible_count += _PAGE_SIZE
        self._build_window()

    def _do_select_all(self) -> None:
        n = min(self._visible_count, len(self._items))
        for item in self._items[:n]:
            cb = item.get("checkbox")
            if cb is not None:
                cb.setState_(NSControlStateValueOn)
            self._checkbox_states[item["term"]] = True

    def _do_deselect_all(self) -> None:
        n = min(self._visible_count, len(self._items))
        for item in self._items[:n]:
            cb = item.get("checkbox")
            if cb is not None:
                cb.setState_(NSControlStateValueOff)
            self._checkbox_states[item["term"]] = False

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _make_label(
        text: str,
        frame: NSRect,
        font_size: float = 13.0,
        secondary: bool = False,
        align_right: bool = False,
    ) -> NSTextField:
        label = NSTextField.alloc().initWithFrame_(frame)
        label.setStringValue_(text)
        label.setEditable_(False)
        label.setBordered_(False)
        label.setDrawsBackground_(False)
        label.setFont_(NSFont.systemFontOfSize_(font_size))
        label.setTextColor_(NSColor.secondaryLabelColor() if secondary else NSColor.labelColor())
        if align_right:
            from AppKit import NSTextAlignmentRight
            label.setAlignment_(NSTextAlignmentRight)
        return label

    @staticmethod
    def _make_button(title: str, y: int, x: int, width: int, height: int = _BTN_H) -> NSButton:
        btn = NSButton.alloc().initWithFrame_(NSRect(NSPoint(x, y), NSSize(width, height)))
        btn.setTitle_(title)
        btn.setBezelStyle_(2)
        return btn
