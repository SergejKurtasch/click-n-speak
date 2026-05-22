"""TermsPanel — NSWindow for reviewing and managing user vocabulary terms."""
from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Callable

import objc
from AppKit import (
    NSApplication,
    NSBackingStoreBuffered,
    NSButton,
    NSColor,
    NSFont,
    NSPoint,
    NSRect,
    NSScreen,
    NSScrollView,
    NSSegmentedControl,
    NSSize,
    NSTableColumn,
    NSTableView,
    NSTextField,
    NSViewHeightSizable,
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

from .utils import LANG_NAMES, log_error


_WIN_W = 600
_WIN_H = 480
_MARGIN = 12
_BTN_H = 30
_SEG_H = 28
_STATS_H = 18
_ROW_H = 20
_MIN_LIST_H = 160
_MAX_SCREEN_H_RATIO = 0.85

# (identifier, header title, default_width, min_width, max_width)
_COLUMNS: list[tuple[str, str, float, float, float]] = [
    ("term",      "Термин",    195, 80, 360),
    ("lang",      "Язык",       42, 35,  58),
    ("source",    "Источник",   78, 55, 110),
    ("use_count", "Исп.",       44, 28,  68),
    ("last_seen", "Последнее",  90, 60, 140),
    ("status",    "",           28, 22,  36),
]

_SOURCE_LABELS: dict[str, str] = {
    "manual":     "вручную",
    "auto":       "авто",
    "correction": "правки",
}

try:
    _NSNotFound = int(__import__("Foundation").NSNotFound)
except Exception:
    _NSNotFound = 0x7FFFFFFF


def _fmt_relative(ts: str | None) -> str:
    if not ts:
        return "—"
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        days = max(0, (datetime.now(UTC) - dt).days)
        if days == 0:
            return "сегодня"
        if days == 1:
            return "вчера"
        if days < 30:
            return f"{days}д"
        months = days // 30
        if months < 12:
            return f"{months}мес"
        return f"{days // 365}г"
    except Exception:
        return (ts or "")[:10]


class _TermsDataSource(NSObject):
    """Cell-based NSTableViewDataSource providing string values per column."""

    def init(self):
        self = objc.super(_TermsDataSource, self).init()
        self._rows: list[tuple[str, dict]] = []
        return self

    @objc.python_method
    def set_rows(self, rows: list[tuple[str, dict]]) -> None:
        self._rows = list(rows)

    def numberOfRowsInTableView_(self, tv) -> int:
        return len(self._rows)

    def tableView_objectValueForTableColumn_row_(self, tv, col, row: int) -> Any:
        if row < 0 or row >= len(self._rows):
            return ""
        lang, item = self._rows[row]
        ident = str(col.identifier())
        if ident == "term":
            return str(item.get("term", ""))
        if ident == "lang":
            return lang.upper()
        if ident == "source":
            return _SOURCE_LABELS.get(str(item.get("source", "manual")), str(item.get("source", "")))
        if ident == "use_count":
            return str(item.get("use_count", 0))
        if ident == "last_seen":
            return _fmt_relative(item.get("last_seen") or item.get("added_at"))
        if ident == "status":
            return "⛔" if item.get("inactive") else ""
        return ""


class _TermsPanelDelegate(NSObject):
    """ObjC target for button/segment actions and NSTableViewDelegate callbacks."""

    def init(self):
        self = objc.super(_TermsPanelDelegate, self).init()
        self._owner: TermsPanel | None = None
        return self

    @objc.python_method
    def set_owner(self, owner: "TermsPanel") -> None:
        self._owner = owner

    def deleteSelected_(self, sender) -> None:
        if self._owner:
            self._owner._do_delete_selected()

    def closePanel_(self, sender) -> None:
        if self._owner:
            self._owner.close()

    def langChanged_(self, sender) -> None:
        if self._owner:
            self._owner._on_lang_changed(int(sender.selectedSegment()))

    def tableViewSelectionDidChange_(self, notification) -> None:
        if self._owner:
            self._owner._update_delete_button()


class TermsPanel:
    """Non-blocking NSWindow: NSTableView showing all user_terms with metadata."""

    def __init__(self) -> None:
        self._window: NSWindow | None = None
        self._delegate = _TermsPanelDelegate.alloc().init()
        self._delegate.set_owner(self)
        self._data_source = _TermsDataSource.alloc().init()
        self._all_rows: list[tuple[str, dict]] = []
        self._filtered_rows: list[tuple[str, dict]] = []
        self._current_lang: str | None = None
        self._seg_langs: list[str | None] = []
        self._on_delete: Callable[[list[tuple[str, str]]], None] | None = None
        self._table: NSTableView | None = None
        self._stats_label: NSTextField | None = None
        self._delete_btn: NSButton | None = None
        self._seg_ctrl: NSSegmentedControl | None = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def show(
        self,
        config: dict,
        on_delete: Callable[[list[tuple[str, str]]], None],
    ) -> None:
        """Open (or refresh) the panel.

        config: current app config — read to populate the table.
        on_delete([(lang, term), ...]): fired after each confirmed deletion.
        """
        self._on_delete = on_delete
        self._all_rows = self._extract_rows(config)
        self._current_lang = None
        self._apply_filter()
        if self._window:
            self._reload_table()
            self._window.makeKeyAndOrderFront_(None)
            self._window.orderFrontRegardless()
        else:
            self._build_window()

    def close(self) -> None:
        if self._window:
            self._window.close()
            self._window = None
        self._table = None
        self._stats_label = None
        self._delete_btn = None
        self._seg_ctrl = None

    # ------------------------------------------------------------------
    # Data helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _extract_rows(config: dict) -> list[tuple[str, dict]]:
        rows: list[tuple[str, dict]] = []
        for lang, items in (config.get("user_terms") or {}).items():
            for item in items:
                if isinstance(item, dict):
                    rows.append((lang, item))
        # Active first, then by use_count desc
        rows.sort(key=lambda r: (r[1].get("inactive") is True, -(r[1].get("use_count") or 0)))
        return rows

    def _apply_filter(self) -> None:
        if self._current_lang is None:
            self._filtered_rows = list(self._all_rows)
        else:
            self._filtered_rows = [(l, it) for l, it in self._all_rows if l == self._current_lang]

    def _reload_table(self) -> None:
        self._data_source.set_rows(self._filtered_rows)
        if self._table is not None:
            self._table.reloadData()
        self._update_stats_label()
        self._update_delete_button()
        self._update_seg_labels()

    # ------------------------------------------------------------------
    # Window construction
    # ------------------------------------------------------------------

    def _build_window(self) -> None:
        screen = NSScreen.mainScreen()
        sf = screen.visibleFrame()
        window_h = min(_WIN_H, sf.size.height * _MAX_SCREEN_H_RATIO)

        btn_y = _MARGIN
        stats_y = btn_y + _BTN_H + 6
        list_y = stats_y + _STATS_H + _MARGIN
        seg_y = window_h - _MARGIN - _SEG_H
        list_h = max(_MIN_LIST_H, seg_y - _MARGIN - list_y)

        wx = sf.origin.x + (sf.size.width - _WIN_W) / 2
        wy = sf.origin.y + (sf.size.height - window_h) / 2

        rect = NSRect(NSPoint(wx, wy), NSSize(_WIN_W, window_h))
        mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, mask, NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Управление терминами")
        self._window.setReleasedWhenClosed_(False)
        min_h = _MARGIN + _BTN_H + 6 + _STATS_H + _MARGIN + _MIN_LIST_H + _MARGIN + _SEG_H + _MARGIN
        self._window.setMinSize_(NSSize(_WIN_W - 100, min_h))

        content = self._window.contentView()
        list_w = _WIN_W - 2 * _MARGIN

        # Language filter — NSSegmentedControl (anchored to top)
        langs_present = sorted({l for l, _ in self._all_rows})
        self._seg_langs = [None] + langs_present
        seg_ctrl = NSSegmentedControl.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, seg_y), NSSize(list_w, _SEG_H))
        )
        seg_ctrl.setSegmentCount_(len(self._seg_langs))
        seg_ctrl.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        seg_ctrl.setTarget_(self._delegate)
        seg_ctrl.setAction_("langChanged:")
        seg_ctrl.setSelectedSegment_(0)
        self._seg_ctrl = seg_ctrl
        self._update_seg_labels_on(seg_ctrl, langs_present)
        content.addSubview_(seg_ctrl)

        # NSScrollView + NSTableView (fills space between seg and footer)
        scroll = NSScrollView.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, list_y), NSSize(list_w, list_h))
        )
        scroll.setHasVerticalScroller_(True)
        scroll.setHasHorizontalScroller_(False)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        scroll.setBorderType_(1)

        table = NSTableView.alloc().initWithFrame_(
            NSRect(NSPoint(0, 0), NSSize(list_w, list_h))
        )
        table.setAllowsMultipleSelection_(True)
        table.setAllowsColumnSelection_(False)
        table.setUsesAlternatingRowBackgroundColors_(True)
        table.setRowHeight_(_ROW_H)
        table.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        table.setDataSource_(self._data_source)
        table.setDelegate_(self._delegate)

        for ident, title, width, min_w, max_w in _COLUMNS:
            col = NSTableColumn.alloc().initWithIdentifier_(ident)
            col.setTitle_(title)
            col.setWidth_(width)
            col.setMinWidth_(min_w)
            col.setMaxWidth_(max_w)
            col.setEditable_(False)
            table.addTableColumn_(col)

        scroll.setDocumentView_(table)
        table.sizeToFit()
        content.addSubview_(scroll)
        self._table = table

        # Stats label (anchored to bottom)
        stats_w = list_w - 220
        stats_lbl = NSTextField.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, stats_y), NSSize(stats_w, _STATS_H))
        )
        stats_lbl.setEditable_(False)
        stats_lbl.setBordered_(False)
        stats_lbl.setDrawsBackground_(False)
        stats_lbl.setFont_(NSFont.systemFontOfSize_(11.0))
        stats_lbl.setTextColor_(NSColor.secondaryLabelColor())
        stats_lbl.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        content.addSubview_(stats_lbl)
        self._stats_label = stats_lbl

        # Buttons (anchored to bottom)
        col_w = (list_w - 8) // 2
        del_btn = NSButton.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, btn_y), NSSize(col_w, _BTN_H))
        )
        del_btn.setTitle_("Удалить выбранные")
        del_btn.setBezelStyle_(2)
        del_btn.setEnabled_(False)
        del_btn.setAutoresizingMask_(NSViewMaxYMargin)
        del_btn.setTarget_(self._delegate)
        del_btn.setAction_("deleteSelected:")
        content.addSubview_(del_btn)
        self._delete_btn = del_btn

        close_btn = NSButton.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN + col_w + 8, btn_y), NSSize(col_w, _BTN_H))
        )
        close_btn.setTitle_("Закрыть")
        close_btn.setBezelStyle_(2)
        close_btn.setKeyEquivalent_("\x1b")
        close_btn.setAutoresizingMask_(NSViewMaxYMargin | NSViewMinXMargin)
        close_btn.setTarget_(self._delegate)
        close_btn.setAction_("closePanel:")
        content.addSubview_(close_btn)

        self._data_source.set_rows(self._filtered_rows)
        self._update_stats_label()

        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        self._window.makeKeyAndOrderFront_(None)

    # ------------------------------------------------------------------
    # Live-update helpers
    # ------------------------------------------------------------------

    def _update_seg_labels_on(self, seg: NSSegmentedControl, langs: list[str]) -> None:
        seg.setLabel_forSegment_(f"Все ({len(self._all_rows)})", 0)
        for i, lang in enumerate(langs):
            count = sum(1 for l, _ in self._all_rows if l == lang)
            name = LANG_NAMES.get(lang, lang.upper())
            seg.setLabel_forSegment_(f"{name} ({count})", i + 1)

    def _update_seg_labels(self) -> None:
        if self._seg_ctrl is None:
            return
        langs = [l for l in self._seg_langs if l is not None]
        self._update_seg_labels_on(self._seg_ctrl, langs)

    def _on_lang_changed(self, idx: int) -> None:
        self._current_lang = self._seg_langs[idx] if 0 <= idx < len(self._seg_langs) else None
        self._apply_filter()
        self._reload_table()

    def _update_stats_label(self) -> None:
        if self._stats_label is None:
            return
        active = sum(1 for _, it in self._all_rows if not it.get("inactive"))
        inactive = len(self._all_rows) - active
        if self._current_lang is None:
            text = f"Всего: {active} активных"
            if inactive:
                text += f" / {inactive} неактивных"
        else:
            n_active = sum(
                1 for l, it in self._all_rows
                if l == self._current_lang and not it.get("inactive")
            )
            n_inactive = sum(
                1 for l, it in self._all_rows
                if l == self._current_lang and it.get("inactive")
            )
            lang_name = LANG_NAMES.get(self._current_lang, self._current_lang.upper())
            text = f"{lang_name}: {n_active} активных"
            if n_inactive:
                text += f" / {n_inactive} неактивных"
        self._stats_label.setStringValue_(text)

    def _update_delete_button(self) -> None:
        if self._delete_btn is None or self._table is None:
            return
        n = int(self._table.selectedRowIndexes().count())
        if n > 0:
            self._delete_btn.setTitle_(f"Удалить выбранные ({n})")
            self._delete_btn.setEnabled_(True)
        else:
            self._delete_btn.setTitle_("Удалить выбранные")
            self._delete_btn.setEnabled_(False)

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def _do_delete_selected(self) -> None:
        if self._table is None:
            return
        idx_set = self._table.selectedRowIndexes()
        indices: list[int] = []
        idx = idx_set.firstIndex()
        while idx != _NSNotFound:
            indices.append(int(idx))
            idx = idx_set.indexGreaterThanIndex_(idx)
        if not indices:
            return
        to_delete = [
            (self._filtered_rows[i][0], str(self._filtered_rows[i][1].get("term", "")))
            for i in indices
            if i < len(self._filtered_rows)
        ]
        if not to_delete:
            return

        from AppKit import NSAlert
        n = len(to_delete)
        suffix = "термин" if n == 1 else "терминов"
        alert = NSAlert.alloc().init()
        alert.setMessageText_(f"Удалить {n} {suffix}?")
        alert.setInformativeText_("Удалённые термины больше не будут подсказывать Whisper.")
        alert.addButtonWithTitle_("Удалить")
        alert.addButtonWithTitle_("Отмена")
        if alert.runModal() != 1000:
            return

        to_delete_set: set[tuple[str, str]] = set(to_delete)
        self._all_rows = [
            (l, it) for l, it in self._all_rows
            if (l, str(it.get("term", ""))) not in to_delete_set
        ]
        self._apply_filter()
        self._reload_table()

        if self._on_delete:
            try:
                self._on_delete(list(to_delete_set))
            except Exception as exc:
                log_error(f"TermsPanel on_delete error: {exc}")
