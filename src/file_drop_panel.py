"""
file_drop_panel.py — Drop-zone window for audio file transcription.

Shows a drag-and-drop area with a "Browse in Finder" button.
Calls back with the selected audio file path.
"""
from __future__ import annotations

from pathlib import Path
from typing import Callable, Optional

import objc
from AppKit import (
    NSApplication,
    NSBackingStoreBuffered,
    NSBezelStyleRounded,
    NSBezierPath,
    NSButton,
    NSColor,
    NSDragOperationCopy,
    NSDragOperationNone,
    NSFilenamesPboardType,
    NSFont,
    NSMakeRect,
    NSModalResponseOK,
    NSOpenPanel,
    NSScreen,
    NSTextAlignmentCenter,
    NSTextField,
    NSView,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSObject

from . import i18n
from .utils import log_error, log_info

_AUDIO_EXTENSIONS = frozenset({
    ".wav", ".mp3", ".m4a", ".aiff", ".aif",
    ".flac", ".ogg", ".opus", ".mp4", ".caf",
})

_WIN_W = 440
_WIN_H = 270

# Vertical layout constants (y=0 is bottom of content view in AppKit)
_BTN_Y = 14
_BTN_H = 36
_BTN_W = 220
_DROP_Y = _BTN_Y + _BTN_H + 10   # 60
_DROP_H = _WIN_H - _DROP_Y - 16  # 194
_MARGIN = 20

# ObjC classes registered once at module level to avoid duplicate-registration errors.
_DropZoneViewClass: type | None = None
_WindowDelegateClass: type | None = None


def _is_audio(path: str) -> bool:
    return Path(path).suffix.lower() in _AUDIO_EXTENSIONS


def _make_label(
    text: str,
    x: float,
    y: float,
    w: float,
    h: float,
    *,
    font_size: float = 13.0,
    bold: bool = False,
    secondary: bool = False,
) -> NSTextField:
    f = NSTextField.labelWithString_(text)
    f.setFrame_(NSMakeRect(x, y, w, h))
    f.setAlignment_(NSTextAlignmentCenter)
    f.setFont_(NSFont.boldSystemFontOfSize_(font_size) if bold else NSFont.systemFontOfSize_(font_size))
    f.setEditable_(False)
    f.setBordered_(False)
    f.setDrawsBackground_(False)
    if secondary:
        f.setTextColor_(NSColor.secondaryLabelColor())
    return f


def _get_drop_zone_class() -> type:
    global _DropZoneViewClass
    if _DropZoneViewClass is not None:
        return _DropZoneViewClass

    class _DropZoneView(NSView):
        """NSView that accepts audio file drags and draws a styled drop zone."""

        _drop_callback: Optional[Callable[[str], None]] = None
        _is_highlighted: bool = False

        def initWithFrame_(self, frame):
            self = objc.super(_DropZoneView, self).initWithFrame_(frame)
            if self is not None:
                self.registerForDraggedTypes_([NSFilenamesPboardType])
            return self

        @objc.python_method
        def set_drop_callback(self, cb: Callable[[str], None]) -> None:
            self._drop_callback = cb

        def drawRect_(self, rect) -> None:
            bounds = self.bounds()
            r = 10.0
            inset = 1.5
            ox, oy = bounds.origin.x, bounds.origin.y
            w, h = bounds.size.width, bounds.size.height

            # Background fill
            if self._is_highlighted:
                NSColor.selectedControlColor().setFill()
            else:
                NSColor.quaternaryLabelColor().setFill()
            bg = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(bounds, r, r)
            bg.fill()

            # Border
            inner = NSMakeRect(ox + inset, oy + inset, w - 2 * inset, h - 2 * inset)
            border = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                inner, max(r - inset, 0), max(r - inset, 0)
            )
            border.setLineWidth_(2.0)
            if self._is_highlighted:
                NSColor.controlAccentColor().setStroke()
            else:
                NSColor.separatorColor().setStroke()
            border.stroke()

        def draggingEntered_(self, sender):
            pb = sender.draggingPasteboard()
            files = pb.propertyListForType_(NSFilenamesPboardType)
            if files and _is_audio(str(files[0])):
                self._is_highlighted = True
                self.setNeedsDisplay_(True)
                return NSDragOperationCopy
            return NSDragOperationNone

        def draggingExited_(self, sender) -> None:
            self._is_highlighted = False
            self.setNeedsDisplay_(True)

        def draggingEnded_(self, sender) -> None:
            self._is_highlighted = False
            self.setNeedsDisplay_(True)

        def prepareForDragOperation_(self, sender) -> bool:
            return True

        def performDragOperation_(self, sender) -> bool:
            pb = sender.draggingPasteboard()
            files = pb.propertyListForType_(NSFilenamesPboardType)
            if files:
                path = str(files[0])
                if _is_audio(path) and self._drop_callback is not None:
                    self._is_highlighted = False
                    self.setNeedsDisplay_(True)
                    self._drop_callback(path)
                    return True
            return False

    _DropZoneViewClass = _DropZoneView
    return _DropZoneViewClass


def _get_window_delegate_class() -> type:
    global _WindowDelegateClass
    if _WindowDelegateClass is not None:
        return _WindowDelegateClass

    class _FileDropDelegate(NSObject):
        def init(self):
            self = objc.super(_FileDropDelegate, self).init()
            self._owner = None
            return self

        @objc.python_method
        def set_owner(self, owner: "FileDropPanel") -> None:
            self._owner = owner

        def windowWillClose_(self, notification) -> None:
            if self._owner is not None:
                self._owner._on_window_closed()

        def browseClicked_(self, sender) -> None:
            if self._owner is not None:
                self._owner._browse_finder()

    _WindowDelegateClass = _FileDropDelegate
    return _WindowDelegateClass


class FileDropPanel:
    """Drop-zone window for selecting an audio file for transcription."""

    def __init__(self, on_file: Callable[[str], None]) -> None:
        self._on_file = on_file
        self._window: Optional[object] = None
        self._delegate: Optional[object] = None
        self._finished = False

    def show(self) -> None:
        """Build and display the drop-zone window. Falls back to osascript on error."""
        try:
            self._build_and_show()
        except Exception as exc:
            log_error(f"FileDropPanel: failed to build window: {exc}")
            self._fallback_browse()

    # ------------------------------------------------------------------
    # Private
    # ------------------------------------------------------------------

    def _build_and_show(self) -> None:
        screen = NSScreen.mainScreen()
        sf = screen.visibleFrame()
        wx = sf.origin.x + (sf.size.width - _WIN_W) / 2
        wy = sf.origin.y + (sf.size.height - _WIN_H) / 2

        mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(wx, wy, _WIN_W, _WIN_H),
            mask,
            NSBackingStoreBuffered,
            False,
        )
        win.setTitle_(i18n.t("dialog.file_drop_title"))
        win.setReleasedWhenClosed_(False)

        content = win.contentView()
        drop_x = _MARGIN
        drop_w = _WIN_W - 2 * _MARGIN

        # ── Drop zone view (background + drag handler) ──────────────────
        DropClass = _get_drop_zone_class()
        drop_view = DropClass.alloc().initWithFrame_(
            NSMakeRect(drop_x, _DROP_Y, drop_w, _DROP_H)
        )
        drop_view.set_drop_callback(self._accept_file)
        content.addSubview_(drop_view)

        # Labels are placed on the drop view (so they inherit its coordinate space
        # and drag events propagate to the parent drop view).
        icon = _make_label("🎵", 0, _DROP_H - 62, drop_w, 44, font_size=36)
        drop_view.addSubview_(icon)

        hint = _make_label(
            i18n.t("dialog.file_drop_hint"),
            8, _DROP_H - 100, drop_w - 16, 24,
            font_size=14, bold=True,
        )
        drop_view.addSubview_(hint)

        fmt = _make_label(
            i18n.t("dialog.file_drop_formats"),
            8, 14, drop_w - 16, 18,
            font_size=11, secondary=True,
        )
        drop_view.addSubview_(fmt)

        # ── Browse button ───────────────────────────────────────────────
        DelegateClass = _get_window_delegate_class()
        delegate = DelegateClass.alloc().init()
        delegate.set_owner(self)
        self._delegate = delegate
        win.setDelegate_(delegate)

        btn_x = (_WIN_W - _BTN_W) / 2
        browse_btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(btn_x, _BTN_Y, _BTN_W, _BTN_H)
        )
        browse_btn.setTitle_(i18n.t("btn.browse_finder"))
        browse_btn.setBezelStyle_(NSBezelStyleRounded)
        browse_btn.setFont_(NSFont.systemFontOfSize_(13))
        browse_btn.setTarget_(delegate)
        browse_btn.setAction_("browseClicked:")
        content.addSubview_(browse_btn)

        self._window = win
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        win.makeKeyAndOrderFront_(None)
        win.orderFrontRegardless()

    def _accept_file(self, path: str) -> None:
        if self._finished:
            return
        self._finished = True
        log_info(f"FileDropPanel: accepted file: {path}")
        if self._window is not None:
            self._window.close()
            self._window = None
        try:
            self._on_file(path)
        except Exception as exc:
            log_error(f"FileDropPanel: on_file callback error: {exc}")

    def _browse_finder(self) -> None:
        """Open a native NSOpenPanel for file selection."""
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseFiles_(True)
        panel.setCanChooseDirectories_(False)
        panel.setAllowsMultipleSelection_(False)
        panel.setTitle_(i18n.t("dialog.file_drop_title"))
        panel.setAllowedFileTypes_([ext.lstrip(".") for ext in sorted(_AUDIO_EXTENSIONS)])
        result = panel.runModal()
        if result == NSModalResponseOK:
            url = panel.URL()
            if url:
                self._accept_file(str(url.path()))

    def _on_window_closed(self) -> None:
        """Called when the user closes the window via the × button."""
        if not self._finished:
            self._finished = True
            self._window = None

    def _fallback_browse(self) -> None:
        """osascript fallback if AppKit window fails to build."""
        import subprocess
        try:
            script = (
                'set theFile to choose file with prompt "Select Audio File" '
                'of type {"public.audio", "wav", "m4a"}\n'
                'POSIX path of theFile'
            )
            result = subprocess.check_output(["osascript", "-e", script])
            path = result.decode("utf-8").strip()
            if path and Path(path).exists():
                self._on_file(path)
        except subprocess.CalledProcessError:
            pass
        except Exception as exc:
            log_error(f"FileDropPanel: fallback browse error: {exc}")
