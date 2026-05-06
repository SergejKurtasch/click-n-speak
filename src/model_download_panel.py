"""model_download_panel.py — NSPanel showing real-time download progress for a Whisper model."""
import time
from typing import Callable

import objc
from AppKit import (
    NSApplication,
    NSBackingStoreBuffered,
    NSBezelStyleRounded,
    NSButton,
    NSColor,
    NSFont,
    NSPanel,
    NSPoint,
    NSProgressIndicator,
    NSProgressIndicatorStyleBar,
    NSRect,
    NSScreen,
    NSSize,
    NSTextField,
    NSTextAlignmentLeft,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSObject

from .utils import log_error, log_info

_WIN_W = 420
_WIN_H = 185
_MARGIN = 16


def _make_label(
    text: str, x: float, y: float, w: float, h: float, *, bold: bool = False, small: bool = False
) -> NSTextField:
    f = NSTextField.alloc().initWithFrame_(NSRect(NSPoint(x, y), NSSize(w, h)))
    f.setStringValue_(text)
    f.setBezeled_(False)
    f.setDrawsBackground_(False)
    f.setEditable_(False)
    f.setSelectable_(False)
    f.setAlignment_(NSTextAlignmentLeft)
    if bold:
        f.setFont_(NSFont.boldSystemFontOfSize_(13))
    elif small:
        f.setFont_(NSFont.systemFontOfSize_(11))
        f.setTextColor_(NSColor.secondaryLabelColor())
    else:
        f.setFont_(NSFont.systemFontOfSize_(13))
    return f


class _DownloadPanelDelegate(NSObject):
    def init(self):
        self = objc.super(_DownloadPanelDelegate, self).init()
        self._owner = None
        return self

    @objc.python_method
    def set_owner(self, owner: "ModelDownloadPanel") -> None:
        self._owner = owner

    def cancel_(self, sender):
        if self._owner:
            self._owner._do_cancel()

    def windowWillClose_(self, notification):
        if self._owner:
            self._owner._handle_window_close()


class ModelDownloadPanel:
    """NSPanel with a progress bar, speed/ETA readout, and Cancel button.

    All public methods must be called on the main thread.
    """

    def __init__(self) -> None:
        self._window: NSPanel | None = None
        self._delegate = _DownloadPanelDelegate.alloc().init()
        self._delegate.set_owner(self)
        self._cancel_cb: Callable | None = None
        self._progress_bar: NSProgressIndicator | None = None
        self._status_field: NSTextField | None = None
        self._eta_field: NSTextField | None = None
        self._cancelled = False
        self._done = False
        self._start_time: float = 0.0
        self._total_estimate: int = 0

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def show(
        self,
        label: str,
        model_id: str,
        total_size_estimate: int,
        cancel_callback: Callable,
    ) -> None:
        """Build and display the panel. Call from the main thread."""
        self._cancel_cb = cancel_callback
        self._cancelled = False
        self._done = False
        self._start_time = time.monotonic()
        self._total_estimate = total_size_estimate
        self._build(label, total_size_estimate)

    def update_progress(self, downloaded_bytes: int, total_bytes: int) -> None:
        """Refresh the progress bar and status text. Call from the main thread."""
        if self._done or self._cancelled or not self._window:
            return

        total = total_bytes or self._total_estimate
        elapsed = max(time.monotonic() - self._start_time, 0.1)
        speed_bps = downloaded_bytes / elapsed  # bytes/s since start
        speed_mbps = speed_bps / (1024 * 1024)
        dl_mb = downloaded_bytes / (1024 * 1024)

        if total > 0:
            if downloaded_bytes <= total:
                pct = 100.0 * downloaded_bytes / total
                total_mb = total / (1024 * 1024)
                total_str = f"{total_mb / 1024:.2f} ГБ" if total_mb >= 1024 else f"{total_mb:.0f} МБ"
                status = f"Скачано: {dl_mb:.0f} МБ из {total_str} · {speed_mbps:.1f} МБ/с"
            else:
                # Downloaded exceeds estimate — show bytes only, bar stays near-full
                pct = 99.0
                status = f"Скачано: {dl_mb:.0f} МБ · {speed_mbps:.1f} МБ/с"
            self._progress_bar.setDoubleValue_(pct)

            remaining_bytes = max(total - downloaded_bytes, 0)
            if speed_bps > 0:
                remaining_s = remaining_bytes / speed_bps
                if remaining_s > 3600:
                    eta_str = f"Осталось ~{remaining_s / 3600:.0f} ч"
                elif remaining_s > 60:
                    eta_str = f"Осталось ~{remaining_s / 60:.0f} мин"
                elif remaining_s > 5:
                    eta_str = f"Осталось ~{remaining_s:.0f} сек"
                else:
                    eta_str = "Почти готово…"
            else:
                eta_str = ""
            self._eta_field.setStringValue_(eta_str)
        else:
            status = f"Скачано: {dl_mb:.0f} МБ · {speed_mbps:.1f} МБ/с"

        self._status_field.setStringValue_(status)

    def finish(self, success: bool = True, error: str | None = None) -> None:
        """Close the panel after download finishes. Call from the main thread."""
        self._done = True
        if self._window:
            self._window.setDelegate_(None)
            self._window.close()
            self._window = None

    def close(self) -> None:
        """Close without triggering cancel (used when cancelled externally). Main thread."""
        self._done = True
        if self._window:
            self._window.setDelegate_(None)
            self._window.close()
            self._window = None

    def bring_to_front(self) -> None:
        """Raise the panel above other windows. Call from the main thread."""
        if self._window:
            self._window.makeKeyAndOrderFront_(None)
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _build(self, label: str, total_size_estimate: int) -> None:
        if self._window:
            self._window.setDelegate_(None)
            self._window.close()
            self._window = None

        screen = NSScreen.mainScreen()
        sf = screen.visibleFrame()
        wx = sf.origin.x + (sf.size.width - _WIN_W) / 2
        wy = sf.origin.y + (sf.size.height - _WIN_H) / 2

        rect = NSRect(NSPoint(wx, wy), NSSize(_WIN_W, _WIN_H))
        mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        self._window = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, mask, NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Загрузка модели")
        self._window.setReleasedWhenClosed_(False)
        self._window.setDelegate_(self._delegate)

        content = self._window.contentView()
        inner_w = _WIN_W - 2 * _MARGIN

        y = _WIN_H - _MARGIN

        # Model label
        y -= 22
        name_lbl = _make_label(f"«{label}»", _MARGIN, y, inner_w, 22, bold=True)
        content.addSubview_(name_lbl)

        # Progress bar
        y -= 10 + 16
        self._progress_bar = NSProgressIndicator.alloc().initWithFrame_(
            NSRect(NSPoint(_MARGIN, y), NSSize(inner_w, 16))
        )
        self._progress_bar.setStyle_(NSProgressIndicatorStyleBar)
        if total_size_estimate > 0:
            self._progress_bar.setIndeterminate_(False)
            self._progress_bar.setMinValue_(0.0)
            self._progress_bar.setMaxValue_(100.0)
            self._progress_bar.setDoubleValue_(0.0)
        else:
            self._progress_bar.setIndeterminate_(True)
            self._progress_bar.startAnimation_(None)
        content.addSubview_(self._progress_bar)

        # Status line (downloaded / speed)
        y -= 8 + 16
        self._status_field = _make_label("Подключение…", _MARGIN, y, inner_w, 16, small=True)
        content.addSubview_(self._status_field)

        # ETA line
        y -= 4 + 14
        self._eta_field = _make_label("", _MARGIN, y, inner_w, 14, small=True)
        content.addSubview_(self._eta_field)

        # Cancel button (bottom-right)
        btn_w, btn_h = 90, 28
        btn_x = _WIN_W - _MARGIN - btn_w
        btn_y = _MARGIN
        btn = NSButton.alloc().initWithFrame_(NSRect(NSPoint(btn_x, btn_y), NSSize(btn_w, btn_h)))
        btn.setTitle_("Отмена")
        btn.setBezelStyle_(NSBezelStyleRounded)
        btn.setTarget_(self._delegate)
        btn.setAction_("cancel:")
        content.addSubview_(btn)

        self._window.makeKeyAndOrderFront_(None)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)

    def _do_cancel(self) -> None:
        """Cancel button clicked — cancel download and close panel."""
        if self._done or self._cancelled:
            return
        self._cancelled = True
        self._done = True
        log_info("ModelDownloadPanel: user cancelled download")
        if self._window:
            self._window.setDelegate_(None)
        if self._cancel_cb:
            try:
                self._cancel_cb()
            except Exception as exc:
                log_error(f"ModelDownloadPanel cancel_cb error: {exc}")
        if self._window:
            self._window.close()
            self._window = None

    def _handle_window_close(self) -> None:
        """Window close button (red X) — treat as cancel."""
        if self._done or self._cancelled:
            return
        self._cancelled = True
        self._done = True
        log_info("ModelDownloadPanel: window closed by user — treating as cancel")
        if self._cancel_cb:
            try:
                self._cancel_cb()
            except Exception as exc:
                log_error(f"ModelDownloadPanel cancel_cb error: {exc}")
        self._window = None  # already closing, don't call close() again
