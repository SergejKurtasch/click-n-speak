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
    NSScrollView,
    NSTextField,
    NSTextAlignmentRight,
    NSView,
    NSViewHeightSizable,
    NSViewMaxYMargin,
    NSViewMinYMargin,
    NSViewWidthSizable,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskResizable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSObject

from .utils import LANG_NAMES, log_error, log_info

_PAGE_SIZE = 10
_WIN_W = 480
_MARGIN = 12
_BTN_H = 30
_ROW_H = 28
_LABEL_H = 22
_HELP_H = 32
_SHOW_MORE_BTN_H = 26
_SELECT_ROW_H = 26
_MIN_LIST_H = 140
_MAX_SCREEN_H_RATIO = 0.85


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

    def selectSection_(self, sender):
        if self._owner:
            self._owner._do_select_section(int(sender.tag()))

    def deselectSection_(self, sender):
        if self._owner:
            self._owner._do_deselect_section(int(sender.tag()))


class _FlippedView(NSView):
    """Top-left coordinate system for predictable list rendering in scroll view."""

    def isFlipped(self):
        return True


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
        # Language order computed each build — maps section-button tag → lang
        self._ordered_langs: list[str] = []

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

        # Language grouping — compute before layout so header rows affect window height
        ordered_langs = self._get_ordered_langs()
        self._ordered_langs = ordered_langs
        multi_lang = len(ordered_langs) > 1
        visible_items = self._items[:n]
        header_rows = (
            sum(1 for lang in ordered_langs if any(it["lang"] == lang for it in visible_items))
            if multi_lang else 0
        )

        # Center on screen.
        screen = NSScreen.mainScreen()
        sf = screen.visibleFrame()

        fixed_h = (
            _MARGIN
            + _BTN_H
            + _MARGIN
            + (_SHOW_MORE_BTN_H + 8 if has_more else 0)
            + 8
            + _SELECT_ROW_H
            + 6
            + _HELP_H
            + 4
            + _LABEL_H
            + _MARGIN
        )
        desired_h = fixed_h + ((n + header_rows) * _ROW_H)
        max_h = sf.size.height * _MAX_SCREEN_H_RATIO
        # Window must always be tall enough to show the minimum list area.
        window_h = min(max(desired_h, fixed_h + _MIN_LIST_H), max_h)
        list_h = max(_MIN_LIST_H, window_h - fixed_h)

        btn_y = _MARGIN
        show_more_y = btn_y + _BTN_H + _MARGIN
        list_y = show_more_y + (_SHOW_MORE_BTN_H + 8 if has_more else 0)
        select_row_y = list_y + list_h + 8
        help_y = select_row_y + _SELECT_ROW_H + 6
        label_y = help_y + _HELP_H + 4

        wx = sf.origin.x + (sf.size.width - _WIN_W) / 2
        wy = sf.origin.y + (sf.size.height - window_h) / 2

        rect = NSRect(NSPoint(wx, wy), NSSize(_WIN_W, window_h))
        mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, mask, NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Новые термины для словаря")
        self._window.setReleasedWhenClosed_(False)
        self._window.setMinSize_(NSSize(_WIN_W, fixed_h + _MIN_LIST_H))

        content = self._window.contentView()

        # Description label
        desc = self._make_label(
            "Выберите термины для словаря Whisper (из последних 100 фраз):",
            NSRect(NSPoint(_MARGIN, label_y), NSSize(_WIN_W - 2 * _MARGIN, _LABEL_H)),
            font_size=12.0,
        )
        desc.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(desc)

        # Explanatory help text
        help_label = self._make_label(
            "Добавленные слова помогут Whisper лучше их узнавать. Удалить можно позже в Manage Terms.",
            NSRect(NSPoint(_MARGIN, help_y), NSSize(_WIN_W - 2 * _MARGIN, _HELP_H)),
            font_size=11.0,
            secondary=True,
        )
        help_label.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        help_label.cell().setWraps_(True)
        content.addSubview_(help_label)

        # "Select all" / "Deselect all" mini-buttons
        mini_w = 120
        sel_btn = self._make_button("Выбрать все", select_row_y, _MARGIN, mini_w, height=_SELECT_ROW_H)
        sel_btn.setAutoresizingMask_(NSViewMinYMargin)
        sel_btn.setTarget_(self._delegate)
        sel_btn.setAction_("selectAll:")
        content.addSubview_(sel_btn)

        desel_btn = self._make_button("Снять все", select_row_y, _MARGIN + mini_w + 8, mini_w, height=_SELECT_ROW_H)
        desel_btn.setAutoresizingMask_(NSViewMinYMargin)
        desel_btn.setTarget_(self._delegate)
        desel_btn.setAction_("deselectAll:")
        content.addSubview_(desel_btn)

        # Scrollable list area with checkboxes + count badges.
        list_w = _WIN_W - 2 * _MARGIN
        scroll = NSScrollView.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, list_y), NSSize(list_w, list_h))
        )
        scroll.setHasVerticalScroller_(True)
        scroll.setHasHorizontalScroller_(False)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        scroll.setBorderType_(1)  # NSBezelBorder

        total_rows = n + header_rows
        doc_h = max(int(list_h), total_rows * _ROW_H)
        doc = _FlippedView.alloc().initWithFrame_(NSRect(NSPoint(0, 0), NSSize(list_w, doc_h)))

        # Checkboxes with count badges — grouped by language when multi_lang.
        current_y = 0
        for lang_idx, lang in enumerate(ordered_langs):
            lang_items = [it for it in visible_items if it["lang"] == lang]
            if not lang_items:
                continue

            if multi_lang:
                lang_name = LANG_NAMES.get(lang, lang.upper())
                n_total_lang = sum(1 for it in self._items if it["lang"] == lang)
                header_lbl = self._make_label(
                    f"── {lang_name} ({n_total_lang}) ──",
                    NSRect(NSPoint(8, current_y + 3), NSSize(list_w - 168, _ROW_H - 6)),
                    font_size=11.0,
                    secondary=True,
                )
                header_lbl.setFont_(NSFont.boldSystemFontOfSize_(11.0))
                doc.addSubview_(header_lbl)

                sec_sel = self._make_button(
                    "выбрать", current_y, list_w - 158, 70, height=_ROW_H - 6
                )
                sec_sel.setTag_(lang_idx)
                sec_sel.setTarget_(self._delegate)
                sec_sel.setAction_("selectSection:")
                doc.addSubview_(sec_sel)

                sec_desel = self._make_button(
                    "снять", current_y, list_w - 82, 70, height=_ROW_H - 6
                )
                sec_desel.setTag_(lang_idx)
                sec_desel.setTarget_(self._delegate)
                sec_desel.setAction_("deselectSection:")
                doc.addSubview_(sec_desel)

                current_y += _ROW_H

            for item in lang_items:
                checkbox = NSButton.alloc().initWithFrame_(
                    NSRect(NSPoint(8, current_y), NSSize(list_w - 75, _ROW_H - 4))
                )
                checkbox.setButtonType_(NSButtonTypeSwitch)
                checkbox.setTitle_(item["term"])
                checkbox.setFont_(NSFont.systemFontOfSize_(13.0))
                saved = self._checkbox_states.get(item["term"], True)
                checkbox.setState_(NSControlStateValueOn if saved else NSControlStateValueOff)
                doc.addSubview_(checkbox)
                item["checkbox"] = checkbox

                badge = self._make_label(
                    f"{item['count']}×",
                    NSRect(NSPoint(list_w - 65, current_y), NSSize(60, _ROW_H - 4)),
                    font_size=11.0,
                    secondary=True,
                    align_right=True,
                )
                doc.addSubview_(badge)
                current_y += _ROW_H

        scroll.setDocumentView_(doc)
        content.addSubview_(scroll)

        # "Show more" button
        if has_more:
            remaining = len(self._items) - self._visible_count
            more_count = min(_PAGE_SIZE, remaining)
            btn = NSButton.alloc().initWithFrame_(
                NSRect(NSPoint(_MARGIN, show_more_y), NSSize(190, _SHOW_MORE_BTN_H))
            )
            btn.setAutoresizingMask_(NSViewMaxYMargin)
            btn.setTitle_(f"Показать ещё {more_count}")
            btn.setTarget_(self._delegate)
            btn.setAction_("showMore:")
            btn.setBezelStyle_(2)
            content.addSubview_(btn)

        # Bottom buttons — three equal-width columns
        col_w = (_WIN_W - 2 * _MARGIN - 16) // 3

        auto_btn = self._make_button("Авто-режим", btn_y, _MARGIN, col_w)
        auto_btn.setAutoresizingMask_(NSViewMaxYMargin)
        auto_btn.setTarget_(self._delegate)
        auto_btn.setAction_("autoMode:")
        content.addSubview_(auto_btn)

        skip_btn = self._make_button("Напомнить позже", btn_y, _MARGIN + col_w + 8, col_w)
        skip_btn.setAutoresizingMask_(NSViewMaxYMargin)
        skip_btn.setTarget_(self._delegate)
        skip_btn.setAction_("skip:")
        skip_btn.setKeyEquivalent_("\x1b")
        content.addSubview_(skip_btn)

        accept_btn = self._make_button("Добавить выбранные", btn_y, _MARGIN + 2 * (col_w + 8), col_w)
        accept_btn.setAutoresizingMask_(NSViewMaxYMargin)
        accept_btn.setTarget_(self._delegate)
        accept_btn.setAction_("accept:")
        accept_btn.setKeyEquivalent_("\r")
        content.addSubview_(accept_btn)

        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        self._window.makeKeyAndOrderFront_(None)
        # Belt-and-suspenders: force window to front even if another app
        # grabbed focus after activateIgnoringOtherApps_ (common after modal).
        self._window.orderFrontRegardless()

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

    def _get_ordered_langs(self) -> list[str]:
        """Return languages sorted by total candidate count descending."""
        lang_counts: dict[str, int] = {}
        for item in self._items:
            lang_counts[item["lang"]] = lang_counts.get(item["lang"], 0) + item["count"]
        return sorted(lang_counts.keys(), key=lambda l: -lang_counts[l])

    def _do_select_section(self, idx: int) -> None:
        if idx >= len(self._ordered_langs):
            return
        lang = self._ordered_langs[idx]
        n = min(self._visible_count, len(self._items))
        for item in self._items[:n]:
            if item["lang"] == lang:
                cb = item.get("checkbox")
                if cb is not None:
                    cb.setState_(NSControlStateValueOn)
                self._checkbox_states[item["term"]] = True

    def _do_deselect_section(self, idx: int) -> None:
        if idx >= len(self._ordered_langs):
            return
        lang = self._ordered_langs[idx]
        n = min(self._visible_count, len(self._items))
        for item in self._items[:n]:
            if item["lang"] == lang:
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
