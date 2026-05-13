"""ReplacementsPanel — edit manual and automatic misrecognition replacement pairs."""

from __future__ import annotations

import copy
import re
from typing import Any, Callable

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
    NSTextAlignmentRight,
    NSTextField,
    NSView,
    NSViewHeightSizable,
    NSViewMaxXMargin,
    NSViewMaxYMargin,
    NSViewMinXMargin,
    NSViewMinYMargin,
    NSViewWidthSizable,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskResizable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSObject

from .utils import canonical_term_key, log_error

_WIN_W = 520
_MARGIN = 12
_BTN_H = 30
_ROW_H = 28
_LABEL_H = 44
_SUMMARY_H = 18
_ADD_ROW_H = 26
_FIELD_W = 200
_MIN_LIST_H = 140
_MAX_SCREEN_H_RATIO = 0.85

_CYRILLIC_RE = re.compile(r"[А-Яа-яЁё]")
_LATIN_RE = re.compile(r"[A-Za-z]")


def _is_cross_script(from_str: str, to_str: str) -> bool:
    """True when *from* and *to* use different scripts (e.g. ru→en or en→ru)."""
    def scripts(s: str) -> frozenset[str]:
        sc: set[str] = set()
        if _CYRILLIC_RE.search(s):
            sc.add("cyr")
        if _LATIN_RE.search(s):
            sc.add("lat")
        return frozenset(sc)

    sf, st = scripts(from_str), scripts(to_str)
    return bool(sf and st and sf != st)


def _sort_key(item: dict[str, Any]) -> tuple[int, int, str]:
    """Sort: manual first, then cross-script, then same-script; within group by count desc."""
    if item.get("source") == "manual":
        group = 0
    elif _is_cross_script(str(item.get("from", "")), str(item.get("to", ""))):
        group = 1
    else:
        group = 2
    count = -int(item.get("count") or 0)
    return (group, count, str(item.get("from", "")).lower())


def _make_summary(items: list[dict[str, Any]], total_singles: int) -> str:
    manual = sum(1 for it in items if it.get("source") == "manual")
    cross = sum(1 for it in items if it.get("source") != "manual" and _is_cross_script(str(it.get("from", "")), str(it.get("to", ""))))
    same = sum(1 for it in items if it.get("source") != "manual" and not _is_cross_script(str(it.get("from", "")), str(it.get("to", ""))))
    parts = []
    if manual:
        parts.append(f"{manual} manual")
    if cross:
        parts.append(f"{cross} cross-script")
    if same:
        parts.append(f"{same} same-script")
    suffix = f" · {total_singles} hidden singles" if total_singles else ""
    return "  ·  ".join(parts) + suffix if parts else "no pairs"


class _ReplacementsPanelDelegate(NSObject):
    def init(self):
        self = objc.super(_ReplacementsPanelDelegate, self).init()
        self._owner = None
        return self

    @objc.python_method
    def set_owner(self, owner: "ReplacementsPanel") -> None:
        self._owner = owner

    def done_(self, sender):
        if self._owner:
            self._owner._do_done()

    def deleteSelected_(self, sender):
        if self._owner:
            self._owner._do_delete_selected()

    def addPair_(self, sender):
        if self._owner:
            self._owner._do_add_pair()

    def toggleSingles_(self, sender):
        if self._owner:
            self._owner._do_toggle_singles()


class _ReplacementsFlippedView(NSView):
    def isFlipped(self):
        return True


class ReplacementsPanel:
    """NSWindow for viewing manual + auto replacement pairs."""

    def __init__(self) -> None:
        self._window: NSWindow | None = None
        self._delegate = _ReplacementsPanelDelegate.alloc().init()
        self._delegate.set_owner(self)
        self._all_items: list[dict[str, Any]] = []  # all pairs (never filtered)
        self._items: list[dict[str, Any]] = []       # currently displayed
        self._checkbox_states: dict[str, bool] = {}
        self._show_singles: bool = False             # show count==1 auto pairs
        self._on_commit: Callable[[list[dict[str, Any]]], None] | None = None
        self._add_from_field: NSTextField | None = None
        self._add_to_field: NSTextField | None = None

    def show(
        self,
        rows: list[dict[str, Any]],
        on_commit: Callable[[list[dict[str, Any]]], None],
    ) -> None:
        """*rows* rows from ``list_replacement_rows_for_ui``; *on_commit* receives final row dicts."""
        self._on_commit = on_commit
        self._all_items = []
        for r in rows:
            d = copy.deepcopy(r)
            d.pop("checkbox", None)
            self._all_items.append(d)
        # Sort: manual → cross-script → same-script, then count desc.
        self._all_items.sort(key=_sort_key)
        # Switches mark pairs for removal — default off so «Удалить выбранные» cannot wipe the list.
        self._checkbox_states = {self._row_key(d): False for d in self._all_items}
        self._apply_filter()
        self._build_window()

    def _apply_filter(self) -> None:
        """Rebuild _items from _all_items based on _show_singles flag."""
        if self._show_singles:
            self._items = list(self._all_items)
        else:
            self._items = [
                it for it in self._all_items
                if it.get("source") == "manual" or int(it.get("count") or 0) >= 2
            ]

    def close(self) -> None:
        self._close_window()

    @staticmethod
    def _row_key(d: dict[str, Any]) -> str:
        return f"{d.get('source')}|{d.get('from')}|{d.get('to')}|{d.get('bucket') or ''}"

    def _close_window(self) -> None:
        if self._window:
            self._window.close()
            self._window = None
        for it in self._items:
            it.pop("checkbox", None)

    def _save_checkbox_states(self) -> None:
        for it in self._items:
            cb = it.get("checkbox")
            if cb is not None:
                self._checkbox_states[self._row_key(it)] = cb.state() == NSControlStateValueOn

    def _build_window(self) -> None:
        self._save_checkbox_states()
        if self._window:
            self._window.close()
            self._window = None
        for it in self._items:
            it.pop("checkbox", None)

        n = len(self._items)
        singles_count = sum(
            1 for it in self._all_items
            if it.get("source") != "manual" and int(it.get("count") or 0) < 2
        )
        screen = NSScreen.mainScreen()
        sf = screen.visibleFrame()

        # Layout (bottom-up): buttons, add-row, summary, list, description
        fixed_h = _MARGIN + _BTN_H + _MARGIN + _ADD_ROW_H + _MARGIN + _SUMMARY_H + _MARGIN + _LABEL_H + _MARGIN
        desired_h = fixed_h + max(_MIN_LIST_H, n * _ROW_H + 8)
        max_h = max(_MIN_LIST_H + fixed_h, sf.size.height * _MAX_SCREEN_H_RATIO)
        window_h = min(desired_h, max_h)
        list_h = max(_MIN_LIST_H, window_h - fixed_h)

        btn_y = _MARGIN
        add_y = btn_y + _BTN_H + _MARGIN
        summary_y = add_y + _ADD_ROW_H + _MARGIN
        list_y = summary_y + _SUMMARY_H + _MARGIN
        label_y = list_y + list_h + _MARGIN

        wx = sf.origin.x + (sf.size.width - _WIN_W) / 2
        wy = sf.origin.y + (sf.size.height - window_h) / 2

        rect = NSRect(NSPoint(wx, wy), NSSize(_WIN_W, window_h))
        mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, mask, NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Пары автозамены")
        self._window.setReleasedWhenClosed_(False)
        self._window.setMinSize_(NSSize(_WIN_W, fixed_h + _MIN_LIST_H))

        content = self._window.contentView()

        desc = self._make_label(
            "Подсказки для редактора и прямая замена в тексте (если AI не менял вывод). "
            "Ручные пары задаются ниже; «авто» собираются из ваших правок в попапе. "
            "Включите переключатель у пары и нажмите «Удалить выбранные», чтобы убрать её из списка.",
            NSRect(NSPoint(_MARGIN, label_y), NSSize(_WIN_W - 2 * _MARGIN, _LABEL_H)),
            font_size=12.0,
        )
        desc.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(desc)

        list_w = _WIN_W - 2 * _MARGIN
        scroll = NSScrollView.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, list_y), NSSize(list_w, list_h))
        )
        scroll.setHasVerticalScroller_(True)
        scroll.setHasHorizontalScroller_(False)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        scroll.setBorderType_(1)

        doc_h = max(int(list_h), max(n * _ROW_H, 1))
        doc = _ReplacementsFlippedView.alloc().initWithFrame_(NSRect(NSPoint(0, 0), NSSize(list_w, doc_h)))

        for i, item in enumerate(self._items):
            row_y = i * _ROW_H
            label = f"{item['from']} → {item['to']}"
            if len(label) > 52:
                label = label[:49] + "…"
            checkbox = NSButton.alloc().initWithFrame_(
                NSRect(NSPoint(8, row_y), NSSize(list_w - 95, _ROW_H - 4))
            )
            checkbox.setButtonType_(NSButtonTypeSwitch)
            checkbox.setTitle_(label)
            checkbox.setFont_(NSFont.systemFontOfSize_(13.0))
            rk = self._row_key(item)
            saved = self._checkbox_states.get(rk, False)
            checkbox.setState_(NSControlStateValueOn if saved else NSControlStateValueOff)
            # Dim low-confidence pairs visually (count < 2) — still selectable for deletion.
            if item.get("source") != "manual" and int(item.get("count") or 0) < 2:
                checkbox.setAlphaValue_(0.5)
            doc.addSubview_(checkbox)
            item["checkbox"] = checkbox

            if item.get("source") == "manual":
                badge_txt = "manual"
            elif _is_cross_script(str(item.get("from", "")), str(item.get("to", ""))):
                c = int(item.get("count") or 0)
                badge_txt = f"{c}× / cross"
            else:
                c = int(item.get("count") or 0)
                badge_txt = f"{c}× / авто"
            badge = self._make_label(
                badge_txt,
                NSRect(NSPoint(list_w - 85, row_y), NSSize(80, _ROW_H - 4)),
                font_size=11.0,
                secondary=True,
                align_right=True,
            )
            doc.addSubview_(badge)

        scroll.setDocumentView_(doc)
        content.addSubview_(scroll)

        # Summary row: stats label + toggle button for singles
        summary_label_w = _WIN_W - 2 * _MARGIN - 150
        summary_lbl = self._make_label(
            _make_summary(self._items, singles_count if not self._show_singles else 0),
            NSRect(NSPoint(_MARGIN, summary_y), NSSize(summary_label_w, _SUMMARY_H)),
            font_size=11.0,
            secondary=True,
        )
        summary_lbl.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(summary_lbl)

        if singles_count > 0 or self._show_singles:
            toggle_lbl = "Скрыть редкие" if self._show_singles else f"Показать редкие ({singles_count})"
            toggle_btn = self._make_button(toggle_lbl, summary_y - 3, _WIN_W - _MARGIN - 140, 140, _SUMMARY_H + 6)
            toggle_btn.setAutoresizingMask_(NSViewMinYMargin | NSViewMinXMargin)
            toggle_btn.setTarget_(self._delegate)
            toggle_btn.setAction_("toggleSingles:")
            content.addSubview_(toggle_btn)

        af = NSTextField.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, add_y), NSSize(_FIELD_W, _ADD_ROW_H - 2))
        )
        af.setPlaceholderString_("из …")
        af.setFont_(NSFont.systemFontOfSize_(13.0))
        content.addSubview_(af)
        self._add_from_field = af

        arrow = self._make_label(
            "→",
            NSRect(NSPoint(_MARGIN + _FIELD_W + 8, add_y), NSSize(24, _ADD_ROW_H)),
            font_size=13.0,
        )
        arrow.setAutoresizingMask_(NSViewMaxYMargin)
        content.addSubview_(arrow)

        at = NSTextField.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN + _FIELD_W + 36, add_y), NSSize(_FIELD_W, _ADD_ROW_H - 2))
        )
        at.setPlaceholderString_("в …")
        at.setFont_(NSFont.systemFontOfSize_(13.0))
        content.addSubview_(at)
        self._add_to_field = at

        add_btn = NSButton.alloc().initWithFrame_(
            NSRect(NSPoint(_WIN_W - _MARGIN - 44, add_y), NSSize(36, _ADD_ROW_H))
        )
        add_btn.setTitle_("＋")
        add_btn.setTarget_(self._delegate)
        add_btn.setAction_("addPair:")
        add_btn.setBezelStyle_(2)
        content.addSubview_(add_btn)

        col_w = (_WIN_W - 2 * _MARGIN - 8) // 2
        del_btn = self._make_button("Удалить выбранные", btn_y, _MARGIN, col_w)
        del_btn.setAutoresizingMask_(NSViewMaxYMargin)
        del_btn.setTarget_(self._delegate)
        del_btn.setAction_("deleteSelected:")
        content.addSubview_(del_btn)

        done_btn = self._make_button("Готово", btn_y, _MARGIN + col_w + 8, col_w)
        done_btn.setAutoresizingMask_(NSViewMaxYMargin)
        done_btn.setTarget_(self._delegate)
        done_btn.setAction_("done:")
        done_btn.setKeyEquivalent_("\r")
        content.addSubview_(done_btn)

        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        self._window.makeKeyAndOrderFront_(None)

    def _do_done(self) -> None:
        self._save_checkbox_states()
        # NSButton targets run on the main thread; safe to mutate config in on_commit.
        # Return ALL items (including hidden singles) so they survive the session.
        out: list[dict[str, Any]] = []
        for it in self._all_items:
            row = {
                "source": it["source"],
                "from": it["from"],
                "to": it["to"],
                "count": it.get("count"),
                "bucket": it.get("bucket"),
            }
            if it.get("added_at"):
                row["added_at"] = it["added_at"]
            out.append(row)
        self._close_window()
        if self._on_commit:
            try:
                self._on_commit(out)
            except Exception as exc:
                log_error(f"ReplacementsPanel on_commit error: {exc}")

    def _do_delete_selected(self) -> None:
        """Remove checked pairs from both _items and _all_items."""
        self._save_checkbox_states()
        # Collect keys of pairs marked for deletion from currently displayed items.
        deleted_keys: set[str] = set()
        for it in self._items:
            rk = self._row_key(it)
            cb = it.get("checkbox")
            if cb is not None and cb.state() == NSControlStateValueOn:
                deleted_keys.add(rk)

        new_all: list[dict[str, Any]] = []
        new_states: dict[str, bool] = {}
        for it in self._all_items:
            rk = self._row_key(it)
            if rk in deleted_keys:
                continue
            it.pop("checkbox", None)
            new_all.append(it)
            new_states[rk] = self._checkbox_states.get(rk, False)
        self._all_items = new_all
        self._checkbox_states = new_states
        self._apply_filter()
        self._build_window()

    def _do_toggle_singles(self) -> None:
        self._save_checkbox_states()
        self._show_singles = not self._show_singles
        self._apply_filter()
        self._build_window()

    def _do_add_pair(self) -> None:
        if not self._add_from_field or not self._add_to_field:
            return
        fr = str(self._add_from_field.stringValue() or "").strip()
        to = str(self._add_to_field.stringValue() or "").strip()
        if not fr or not to:
            return
        if canonical_term_key(fr) == canonical_term_key(to):
            return
        key = (canonical_term_key(fr), canonical_term_key(to))
        for it in self._all_items:
            if it.get("source") != "manual":
                continue
            if (canonical_term_key(str(it.get("from", ""))), canonical_term_key(str(it.get("to", "")))) == key:
                return
        self._save_checkbox_states()
        new_item = {
            "source": "manual",
            "from": fr,
            "to": to,
            "count": None,
            "bucket": None,
            "added_at": None,
        }
        # Insert manual pairs at the front (before all other items).
        self._all_items.insert(0, new_item)
        self._checkbox_states[self._row_key(new_item)] = False
        self._add_from_field.setStringValue_("")
        self._add_to_field.setStringValue_("")
        self._apply_filter()
        self._build_window()

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
            label.setAlignment_(NSTextAlignmentRight)
        return label

    @staticmethod
    def _make_button(title: str, y: float, x: float, width: float, height: float = _BTN_H) -> NSButton:
        btn = NSButton.alloc().initWithFrame_(NSRect(NSPoint(x, y), NSSize(width, height)))
        btn.setTitle_(title)
        btn.setBezelStyle_(2)
        return btn
