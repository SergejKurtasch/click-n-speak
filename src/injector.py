import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol

from pynput.keyboard import Controller, Key

from .utils import is_accessibility_trusted, log_error, log_info, send_notification

try:
    from AppKit import NSPasteboard, NSPasteboardItem, NSPasteboardTypeString
    from Foundation import NSData
except ImportError:  # pragma: no cover - exercised on non-macOS CI only
    NSPasteboard = None
    NSPasteboardItem = None
    NSPasteboardTypeString = None
    NSData = None


@dataclass(frozen=True)
class InjectionResult:
    success: bool
    method: str
    char_count: int
    duration_seconds: float
    error: str | None = None


@dataclass(frozen=True)
class PasteboardSnapshot:
    items: tuple[tuple[tuple[str, bytes], ...], ...]


class ClipboardAdapter(Protocol):
    def is_available(self) -> bool: ...

    def snapshot(self) -> PasteboardSnapshot: ...

    def set_text(self, text: str) -> int: ...

    def restore_if_unchanged(
        self,
        snapshot: PasteboardSnapshot,
        expected_change_count: int,
    ) -> bool: ...


class MacPasteboardAdapter:
    """Preserve every pasteboard item/type while temporarily pasting text."""

    def is_available(self) -> bool:
        return all(
            value is not None
            for value in (
                NSPasteboard,
                NSPasteboardItem,
                NSPasteboardTypeString,
                NSData,
            )
        )

    def _pasteboard(self) -> Any:
        if not self.is_available():
            raise RuntimeError("macOS pasteboard is unavailable")
        return NSPasteboard.generalPasteboard()

    def snapshot(self) -> PasteboardSnapshot:
        pasteboard = self._pasteboard()
        serialized_items: list[tuple[tuple[str, bytes], ...]] = []
        for item in pasteboard.pasteboardItems() or []:
            serialized_types: list[tuple[str, bytes]] = []
            for pasteboard_type in item.types() or []:
                data = item.dataForType_(pasteboard_type)
                if data is not None:
                    serialized_types.append((str(pasteboard_type), bytes(data)))
            serialized_items.append(tuple(serialized_types))
        return PasteboardSnapshot(items=tuple(serialized_items))

    def set_text(self, text: str) -> int:
        pasteboard = self._pasteboard()
        pasteboard.clearContents()
        if not pasteboard.setString_forType_(text, NSPasteboardTypeString):
            raise RuntimeError("macOS pasteboard rejected text")
        return int(pasteboard.changeCount())

    def restore_if_unchanged(
        self,
        snapshot: PasteboardSnapshot,
        expected_change_count: int,
    ) -> bool:
        pasteboard = self._pasteboard()
        if int(pasteboard.changeCount()) != expected_change_count:
            log_info("Clipboard changed after injection; preserving the user's new content.")
            return False

        restored_items = []
        for serialized_item in snapshot.items:
            item = NSPasteboardItem.alloc().init()
            for pasteboard_type, raw_data in serialized_item:
                data = NSData.dataWithBytes_length_(raw_data, len(raw_data))
                item.setData_forType_(data, pasteboard_type)
            restored_items.append(item)

        pasteboard.clearContents()
        if restored_items:
            pasteboard.writeObjects_(restored_items)
        return True


def _paste_with_keyboard(keyboard: Controller) -> None:
    keyboard.press(Key.cmd)
    try:
        keyboard.press("v")
        keyboard.release("v")
    finally:
        keyboard.release(Key.cmd)


def _type_with_keyboard(keyboard: Controller, text: str, delay: float) -> None:
    for modifier in (Key.alt, Key.cmd, Key.shift, Key.ctrl):
        keyboard.release(modifier)
    for char in text:
        keyboard.type(char)
        time.sleep(delay)


def inject_text(
    text: str,
    pre_delay: float = 0.0,
    *,
    clipboard: ClipboardAdapter | None = None,
    keyboard_factory: Callable[[], Controller] = Controller,
    restore_delay: float = 0.35,
    typing_delay: float = 0.006,
) -> InjectionResult:
    """Paste text atomically, falling back to throttled character typing."""
    started_at = time.monotonic()
    if not text:
        return InjectionResult(True, "none", 0, 0.0)

    if not is_accessibility_trusted():
        error = "Accessibility permissions are not granted"
        log_error(f"{error}. Cannot inject text.")
        send_notification(
            "Click-n-speak",
            "Permissions Required",
            "Please allow Click-n-speak in System Settings -> Privacy -> Accessibility to enable text insertion.",
        )
        return InjectionResult(
            False,
            "none",
            len(text),
            time.monotonic() - started_at,
            error,
        )

    if pre_delay > 0:
        time.sleep(pre_delay)

    keyboard = keyboard_factory()
    pasteboard = clipboard or MacPasteboardAdapter()
    paste_sent = False
    snapshot: PasteboardSnapshot | None = None
    change_count: int | None = None
    try:
        if pasteboard.is_available():
            snapshot = pasteboard.snapshot()
            change_count = pasteboard.set_text(text)
            log_info(f"Attempting atomic text injection: chars={len(text)}")
            _paste_with_keyboard(keyboard)
            paste_sent = True
            time.sleep(max(0.0, restore_delay))
            pasteboard.restore_if_unchanged(snapshot, change_count)
            elapsed = time.monotonic() - started_at
            log_info(
                f"Text injection successful: method=paste chars={len(text)} "
                f"duration={elapsed:.3f}s"
            )
            return InjectionResult(True, "paste", len(text), elapsed)
    except Exception as exc:
        if paste_sent:
            elapsed = time.monotonic() - started_at
            log_error(f"Paste was sent but clipboard restoration failed: {exc}")
            return InjectionResult(True, "paste", len(text), elapsed, str(exc))
        if snapshot is not None and change_count is not None:
            try:
                pasteboard.restore_if_unchanged(snapshot, change_count)
            except Exception as restore_exc:
                log_error(f"Failed to restore clipboard before typing fallback: {restore_exc}")
        log_error(f"Atomic paste unavailable, falling back to typing: {exc}")

    try:
        log_info(f"Attempting typed text injection: chars={len(text)}")
        _type_with_keyboard(keyboard, text, typing_delay)
        elapsed = time.monotonic() - started_at
        log_info(
            f"Text injection successful: method=typing chars={len(text)} "
            f"duration={elapsed:.3f}s"
        )
        return InjectionResult(True, "typing", len(text), elapsed)
    except Exception as exc:
        elapsed = time.monotonic() - started_at
        log_error(f"Text injection failed: {exc}")
        send_notification(
            "Click-n-speak",
            "Injection Failed",
            "Could not insert text. Check Accessibility permissions.",
        )
        return InjectionResult(False, "typing", len(text), elapsed, str(exc))
