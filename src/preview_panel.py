import threading
import time
from collections.abc import Callable, Iterator
from queue import Queue
import objc
from AppKit import (
    NSPanel,
    NSNonactivatingPanelMask,
    NSFloatingWindowLevel,
    NSBorderlessWindowMask,
    NSColor,
    NSVisualEffectView,
    NSVisualEffectMaterialHUDWindow,
    NSRect,
    NSPoint,
    NSSize,
    NSTextField,
    NSTextAlignmentLeft,
    NSFont,
    NSScreen,
    NSImageView,
    NSImage,
    NSEvent,
    NSObject,
    NSApplication,
    NSScrollView,
    NSTextView,
    NSMenuItem,
    NSForegroundColorAttributeName,
    NSFontAttributeName,
    NSEventModifierFlagCommand,
)
from Foundation import NSAttributedString
from .log_analyzer import TERM_STOPLIST
from .utils import get_menu_icon_path, log_exception, log_info

class KeyablePanel(NSPanel):
    def canBecomeKeyWindow(self):
        return True

    def canBecomeMainWindow(self):
        return True

class TextViewDelegate(NSObject):
    """Delegate for the NSTextView used in interactive mode."""
    def init(self):
        self = objc.super(TextViewDelegate, self).init()
        self.on_confirm = None
        self.on_cancel = None
        return self

    # NSTextViewDelegate: intercept Enter / Escape via doCommandBySelector.
    @objc.typedSelector(b'Z@:@:')
    def textView_doCommandBySelector_(self, text_view, command_selector):
        selector_str = str(command_selector)
        log_info(f"TextViewDelegate.doCommandBySelector: {selector_str!r}")
        if selector_str == "insertNewline:":
            if self.on_confirm:
                self.on_confirm(str(text_view.string()).strip())
            return True
        if selector_str == "cancelOperation:":
            if self.on_cancel:
                self.on_cancel()
            return True
        return False


class DictionaryAwareTextView(NSTextView):
    """NSTextView with Add-to-dictionary context menu item."""

    def menuForEvent_(self, event):
        menu = objc.super(DictionaryAwareTextView, self).menuForEvent_(event)
        if menu is None:
            return None
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Add to Dictionary",
            "addToDictionary:",
            "d",
        )
        item.setKeyEquivalentModifierMask_(NSEventModifierFlagCommand)
        item.setTarget_(self)
        menu.insertItem_atIndex_(item, 0)
        menu.insertItem_atIndex_(NSMenuItem.separatorItem(), 1)
        return menu

    @objc.typedSelector(b'v@:@')
    def addToDictionary_(self, _sender):
        panel_ref = getattr(self, "_panel_ref", None)
        queue_ref = getattr(self, "_queue_ref", None)
        if panel_ref is not None and queue_ref is not None:
            panel_ref._add_selection_to_dictionary(queue_ref)


_NSKeyDownMask = 1 << 10   # NSEventMaskKeyDown
_KEY_RETURN  = 36
_KEY_ENTER   = 76  # numpad Enter
_KEY_ESCAPE  = 53


def _is_term_start_char(char: str) -> bool:
    return bool(char) and char.isalpha()


def _is_term_char(char: str) -> bool:
    return bool(char) and (char.isalnum() or char in "+#._-")


def _iter_term_spans(text: str) -> Iterator[tuple[int, int]]:
    """Yield [start, end) spans for term-like tokens in text."""
    i = 0
    n = len(text)
    while i < n:
        if not _is_term_start_char(text[i]):
            i += 1
            continue
        start = i
        i += 1
        while i < n and _is_term_char(text[i]):
            i += 1
        yield start, i


def _word_at_offset(text: str, offset: int) -> str:
    """Return term-like token containing caret offset, or nearest token."""
    if not text:
        return ""
    safe_offset = max(0, min(int(offset), len(text)))
    best = ""
    best_dist = None
    for start, end in _iter_term_spans(text):
        if start <= safe_offset < end:
            return text[start:end]
        if safe_offset == end and start < end:
            return text[start:end]
        if safe_offset < start:
            dist = start - safe_offset
        else:
            dist = safe_offset - end
        if best_dist is None or dist < best_dist:
            best_dist = dist
            best = text[start:end]
    return best


_MAX_TERM_WORDS = 4
_MAX_TERM_CHARS = 60


def _is_valid_term(word: str) -> bool:
    candidate = " ".join((word or "").split()).strip()
    if len(candidate) < 2 or len(candidate) > _MAX_TERM_CHARS:
        return False
    if candidate.isdigit():
        return False
    if not any(ch.isalpha() for ch in candidate):
        return False
    words = candidate.split()
    if len(words) > _MAX_TERM_WORDS:
        return False
    for w in words:
        if not _is_term_start_char(w[0]):
            return False
        if not all(_is_term_char(ch) for ch in w):
            return False
    # Stoplist only for single-word candidates (multi-word phrases are intentional)
    if len(words) == 1 and candidate.lower() in TERM_STOPLIST:
        return False
    return True


class TranscriptionPreviewPanel:
    def __init__(self):
        self.panel = None
        self.title_field = None
        self.text_field = None    # NSTextField — non-interactive mode only
        self.text_view = None     # NSTextView  — interactive mode only
        self.scroll_view = None   # NSScrollView wrapping text_view
        self.icon_view = None
        self._delegate = None
        self._is_interactive = False
        self._local_monitor = None   # NSEvent local key monitor
        self._global_monitor = None  # NSEvent global key monitor (fallback)
        # Prevents both confirm and cancel from firing for the same keypress
        # (e.g. local + global monitor both deliver the event simultaneously).
        self._handler_lock = threading.Lock()
        self._on_add_to_dictionary = None
        self._toast_added_template = "Added: {term}"
        self._toast_invalid_term = "Not a valid term"
        self._toast_exists = "Already in dictionary"
        self._canonical_title: str = ""

    def _update_position(self, center=False):
        """Position the panel.

        center=True  → upper-centre of the screen the cursor is on.
        center=False → near the mouse cursor (used for the non-interactive HUD).
        """
        if not self.panel:
            return

        width = self.panel.frame().size.width
        height = self.panel.frame().size.height

        # Always resolve the screen from the current mouse location so we land
        # on the right display even with multiple monitors.  NSScreen.mainScreen()
        # is unreliable for LSUIElement (menu-bar-only) apps — it can return a
        # screen the user isn't looking at.
        mouse_loc = NSEvent.mouseLocation()
        screen = NSScreen.mainScreen()  # fallback
        for s in NSScreen.screens():
            sf = s.frame()
            if (sf.origin.x <= mouse_loc.x <= sf.origin.x + sf.size.width and
                    sf.origin.y <= mouse_loc.y <= sf.origin.y + sf.size.height):
                screen = s
                break
        frame = screen.visibleFrame()

        if center:
            # Horizontally centred, near top of the visible area on cursor's screen.
            x = frame.origin.x + (frame.size.width - width) / 2
            y = frame.origin.y + frame.size.height * 0.80 - height
        else:
            x = mouse_loc.x - (width / 2)

            # Prefer below cursor; flip above if not enough space
            y_below = mouse_loc.y - height - 20
            if y_below >= frame.origin.y:
                y = y_below
            else:
                y = mouse_loc.y + 20

        # Clamp
        if x < frame.origin.x:
            x = frame.origin.x
        elif x + width > frame.origin.x + frame.size.width:
            x = frame.origin.x + frame.size.width - width
        if y + height > frame.origin.y + frame.size.height:
            y = frame.origin.y + frame.size.height - height
        if y < frame.origin.y:
            y = frame.origin.y

        log_info(f"_update_position: x={x:.0f} y={y:.0f} center={center}")
        self.panel.setFrameOrigin_(NSPoint(x, y))

    def _create_panel(self, interactive=False):
        # Recreate if mode changed
        if self.panel is not None:
            if self._is_interactive != interactive:
                self.panel.close()
                self.panel = None
                self.text_field = None
                self.text_view = None
                self.scroll_view = None
            else:
                return

        width = 400
        height = 160 if interactive else 120

        mouse_loc = NSEvent.mouseLocation()
        x = mouse_loc.x - (width / 2)
        y = mouse_loc.y - height - 20

        screen = NSScreen.mainScreen()
        frame = screen.visibleFrame()
        if x < frame.origin.x: x = frame.origin.x
        elif x + width > frame.origin.x + frame.size.width: x = frame.origin.x + frame.size.width - width
        if y < frame.origin.y: y = frame.origin.y

        rect = NSRect(NSPoint(x, y), NSSize(width, height))

        # Both interactive and non-interactive use NSNonactivatingPanelMask so the panel
        # is always rendered on top without stealing keyboard focus from the user's app.
        # Enter/Escape are captured via NSEvent monitors regardless.
        mask = NSNonactivatingPanelMask | NSBorderlessWindowMask
        self.panel = KeyablePanel.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, mask, 2, False
        )
        self.panel.setLevel_(NSFloatingWindowLevel)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setHasShadow_(True)
        self.panel.setIgnoresMouseEvents_(not interactive)

        visual_effect = NSVisualEffectView.alloc().initWithFrame_(NSRect(NSPoint(0, 0), NSSize(width, height)))
        visual_effect.setMaterial_(NSVisualEffectMaterialHUDWindow)
        visual_effect.setBlendingMode_(0)
        visual_effect.setState_(1)
        visual_effect.setWantsLayer_(True)
        visual_effect.layer().setCornerRadius_(12.0)

        # ── Icon ──────────────────────────────────────────────────────────────
        icon_path = str(get_menu_icon_path())
        image = NSImage.alloc().initWithContentsOfFile_(icon_path)
        icon_size = 20
        icon_x = 15
        icon_y = height - 15 - icon_size
        self.icon_view = NSImageView.alloc().initWithFrame_(
            NSRect(NSPoint(icon_x, icon_y), NSSize(icon_size, icon_size)))
        if image:
            self.icon_view.setImage_(image)
        visual_effect.addSubview_(self.icon_view)

        # ── Title ─────────────────────────────────────────────────────────────
        title_x = icon_x + icon_size + 10
        title_y = height - 15 - 18          # y of title top (from bottom of window)
        title_bar_bottom = title_y           # same: bottom of title area
        self.title_field = NSTextField.alloc().initWithFrame_(
            NSRect(NSPoint(title_x, title_y), NSSize(width - title_x - 15, 20)))
        self.title_field.setEditable_(False)
        self.title_field.setBordered_(False)
        self.title_field.setBackgroundColor_(NSColor.clearColor())
        self.title_field.setTextColor_(NSColor.whiteColor())
        self.title_field.setFont_(NSFont.boldSystemFontOfSize_(13.0))
        self.title_field.setAlignment_(NSTextAlignmentLeft)
        self.title_field.cell().setTruncatesLastVisibleLine_(True)
        self.title_field.cell().setLineBreakMode_(0)
        visual_effect.addSubview_(self.title_field)

        # ── Text area ─────────────────────────────────────────────────────────
        TEXT_BOTTOM_PAD = 10   # gap from window bottom
        TITLE_GAP       = 10   # gap between title bar and text area
        text_y  = TEXT_BOTTOM_PAD
        text_h  = title_bar_bottom - TEXT_BOTTOM_PAD - TITLE_GAP
        text_w  = width - 30   # 15px padding each side

        if interactive:
            # NSScrollView + NSTextView for proper multiline editing + scrollbar
            scroll_rect = NSRect(NSPoint(15, text_y), NSSize(text_w, text_h))
            self.scroll_view = NSScrollView.alloc().initWithFrame_(scroll_rect)
            self.scroll_view.setHasVerticalScroller_(True)
            self.scroll_view.setHasHorizontalScroller_(False)
            self.scroll_view.setAutohidesScrollers_(False)   # always show scroller
            self.scroll_view.setBorderType_(0)               # NSNoBorder
            self.scroll_view.setDrawsBackground_(True)
            self.scroll_view.setBackgroundColor_(NSColor.colorWithWhite_alpha_(1.0, 0.08))
            self.scroll_view.setWantsLayer_(True)
            self.scroll_view.layer().setCornerRadius_(6.0)

            content_size = self.scroll_view.contentSize()
            tv_rect = NSRect(NSPoint(0, 0), NSSize(content_size.width, content_size.height))
            self.text_view = DictionaryAwareTextView.alloc().initWithFrame_(tv_rect)
            self.text_view.setMinSize_(NSSize(content_size.width, content_size.height))
            self.text_view.setMaxSize_(NSSize(content_size.width, 1e7))
            self.text_view.setVerticallyResizable_(True)
            self.text_view.setHorizontallyResizable_(False)
            self.text_view.textContainer().setContainerSize_(NSSize(content_size.width, 1e7))
            self.text_view.textContainer().setWidthTracksTextView_(True)
            self.text_view.textContainer().setLineFragmentPadding_(4.0)
            self.text_view.setTextColor_(NSColor.whiteColor())
            self.text_view.setFont_(NSFont.systemFontOfSize_(14.0))
            self.text_view.setEditable_(True)
            self.text_view.setSelectable_(True)
            self.text_view.setDrawsBackground_(False)
            self.text_view.setInsertionPointColor_(NSColor.whiteColor())
            self.text_view.setRichText_(False)
            self.text_view.setAutomaticSpellingCorrectionEnabled_(False)
            self.text_view.setAutomaticQuoteSubstitutionEnabled_(False)
            self.text_view.setAutomaticDashSubstitutionEnabled_(False)

            self._delegate = TextViewDelegate.alloc().init()
            self.text_view.setDelegate_(self._delegate)

            self.scroll_view.setDocumentView_(self.text_view)
            visual_effect.addSubview_(self.scroll_view)
            self.text_field = None  # not used in interactive mode

        else:
            # Plain NSTextField for non-interactive status display
            self.text_field = NSTextField.alloc().initWithFrame_(
                NSRect(NSPoint(15, text_y), NSSize(text_w, text_h)))
            self.text_field.setEditable_(False)
            self.text_field.setBordered_(False)
            self.text_field.setBackgroundColor_(NSColor.clearColor())
            self.text_field.setTextColor_(NSColor.colorWithWhite_alpha_(1.0, 0.8))
            self.text_field.cell().setTruncatesLastVisibleLine_(True)
            self.text_field.cell().setLineBreakMode_(0)
            self.text_field.setMaximumNumberOfLines_(3)
            self.text_field.setFont_(NSFont.systemFontOfSize_(14.0))
            self.text_field.setAlignment_(NSTextAlignmentLeft)
            visual_effect.addSubview_(self.text_field)
            self.text_view = None
            self.scroll_view = None

        self.panel.setContentView_(visual_effect)
        self.panel.setAlphaValue_(0.0)
        self._is_interactive = interactive

    def _set_text_view_text(self, text):
        """Set text in the NSTextView with white colour preserved."""
        if not self.text_view:
            return
        attrs = {
            NSForegroundColorAttributeName: NSColor.whiteColor(),
            NSFontAttributeName: NSFont.systemFontOfSize_(14.0),
        }
        attr_str = NSAttributedString.alloc().initWithString_attributes_(text, attrs)
        self.text_view.textStorage().setAttributedString_(attr_str)

    def show(self, title, queue):
        def _do_show():
            self._create_panel(interactive=False)
            self._update_position()
            self.title_field.setStringValue_(title)
            if self.text_field is not None:
                self.text_field.setStringValue_("")
            else:
                log_info("show._do_show: WARNING text_field is None after _create_panel — state mismatch")
            self.panel.orderFront_(None)
            self.panel.animator().setAlphaValue_(0.9)

        queue.put((_do_show, (), {}))

    def _remove_key_monitors(self):
        """Remove local and global NSEvent key monitors (safe to call multiple times)."""
        if self._local_monitor is not None:
            NSEvent.removeMonitor_(self._local_monitor)
            self._local_monitor = None
        if self._global_monitor is not None:
            NSEvent.removeMonitor_(self._global_monitor)
            self._global_monitor = None

    def _flash_toast(self, queue: Queue, message: str, duration: float = 1.5) -> None:
        if not self.title_field:
            return

        canonical = self._canonical_title

        def _apply_toast():
            if not self.title_field:
                return
            self.title_field.setStringValue_(message)
            self.title_field.setTextColor_(NSColor.systemGreenColor())

        def _apply_restore():
            if not self.title_field:
                return
            self.title_field.setStringValue_(canonical)
            self.title_field.setTextColor_(NSColor.whiteColor())

        queue.put((_apply_toast, (), {}))

        def _restore_later():
            time.sleep(duration)
            queue.put((_apply_restore, (), {}))

        threading.Thread(target=_restore_later, daemon=True).start()

    def _add_selection_to_dictionary(self, queue: Queue) -> None:
        if not self.text_view:
            return

        full_text = str(self.text_view.string() or "")
        selected = self.text_view.selectedRange()
        location = max(0, int(selected.location))
        length = max(0, int(selected.length))

        if length > 0 and location < len(full_text):
            candidate = full_text[location: location + length].strip()
        else:
            candidate = _word_at_offset(full_text, location).strip()

        if not _is_valid_term(candidate):
            self._flash_toast(queue, self._toast_invalid_term)
            return

        if not self._on_add_to_dictionary:
            self._flash_toast(queue, self._toast_invalid_term)
            return

        try:
            result = self._on_add_to_dictionary(candidate)
        except Exception as e:
            log_exception(f"[preview_panel] on_add_to_dictionary error: {e}")
            self._flash_toast(queue, self._toast_invalid_term)
            return

        if result:
            # result may be a formatted message string (new) or plain True (legacy)
            msg = result if isinstance(result, str) else self._toast_added_template.format(term=candidate)
            self._flash_toast(queue, msg)
        else:
            self._flash_toast(queue, self._toast_exists)

    def show_interactive(
        self,
        text: str,
        queue: Queue,
        on_confirm: Callable[[str], None],
        on_cancel: Callable[[], None] | None = None,
        title: str = "Редактируй и нажми Enter",
        on_add_to_dictionary: Callable[[str], bool] | None = None,
        toast_added_template: str = "Added: {term}",
        toast_invalid_term: str = "Not a valid term",
        toast_exists: str = "Already in dictionary",
    ) -> None:
        """Shows the panel in interactive mode near the cursor."""
        def _handle_confirm(new_text):
            # _handler_lock ensures only one handler (confirm or cancel) runs to
            # completion even when local + global monitors deliver the same keypress.
            with self._handler_lock:
                if not self._is_interactive:
                    return  # already handled
                self._is_interactive = False  # claim ownership atomically
            new_text = new_text.strip()
            self._remove_key_monitors()
            # Close + null out so next _create_panel(interactive=False) always
            # creates a fresh panel (prevents NoneType crash in show()._do_show()).
            if self.panel:
                self.panel.close()
                self.panel = None
                self.text_view = None
                self.scroll_view = None
            log_info(f"_handle_confirm: confirming with text len={len(new_text)}")
            if on_confirm:
                try:
                    on_confirm(new_text)
                except Exception as e:
                    log_exception(f"[preview_panel] on_confirm error: {e}")

        def _handle_cancel():
            with self._handler_lock:
                if not self._is_interactive:
                    return  # already handled
                self._is_interactive = False  # claim ownership atomically
            self._remove_key_monitors()
            if self.panel:
                self.panel.close()
                self.panel = None
                self.text_view = None
                self.scroll_view = None
            log_info("_handle_cancel: popup cancelled")
            if on_cancel:
                try:
                    on_cancel()
                except Exception as e:
                    log_exception(f"[preview_panel] on_cancel error: {e}")

        def _do_show_interactive():
            try:
                log_info("_do_show_interactive: starting")
                self._remove_key_monitors()  # clean up any leftover monitors from prior session
                self._create_panel(interactive=True)
                log_info(f"_do_show_interactive: panel created, panel={self.panel is not None}")
                self._update_position(center=False)
                self._delegate.on_confirm = _handle_confirm
                self._delegate.on_cancel = _handle_cancel
                self._on_add_to_dictionary = on_add_to_dictionary
                self._toast_added_template = toast_added_template
                self._toast_invalid_term = toast_invalid_term
                self._toast_exists = toast_exists
                self.text_view._panel_ref = self
                self.text_view._queue_ref = queue

                self._canonical_title = title
                self.title_field.setStringValue_(title)
                self._set_text_view_text(text)

                # Show the window (orderFrontRegardless bypasses app-active requirement).
                self.panel.orderFrontRegardless()
                self.panel.setAlphaValue_(0.9)

                # Activate our app so the panel reliably becomes the key window.
                # This is necessary for LSUIElement (menu-bar-only) apps: without explicit
                # activation the panel appears but never receives keyboard events.
                # The previous app is restored in _run_injection via _restore_focus().
                NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
                self.panel.makeKeyWindow()
                self.panel.makeFirstResponder_(self.text_view)
                self.text_view.selectAll_(None)

                log_info(
                    f"_do_show_interactive: isVisible={self.panel.isVisible()}, "
                    f"isKeyWindow={self.panel.isKeyWindow()}, "
                    f"alpha={self.panel.alphaValue():.2f}"
                )

                # Local monitor captures Enter/Escape when our app is key (can consume events).
                # No global monitor: a global monitor fires on Enter/Escape pressed in ANY app,
                # which would silently inject text when the user types in another window.
                def _local_key_handler(event):
                    if not self._is_interactive:
                        return event
                    kc = event.keyCode()
                    log_info(f"local_key_handler: keyCode={kc}")
                    if kc in (_KEY_RETURN, _KEY_ENTER):
                        txt = str(self.text_view.string()).strip() if self.text_view else ""
                        _handle_confirm(txt)
                        return None  # consume — prevents Enter reaching other windows
                    if kc == _KEY_ESCAPE:
                        _handle_cancel()
                        return None  # consume
                    if int(event.modifierFlags()) & int(NSEventModifierFlagCommand):
                        chars = str(event.charactersIgnoringModifiers() or "").lower()
                        if chars == "d":
                            self._add_selection_to_dictionary(queue)
                            return None  # consume
                    return event

                self._local_monitor = None
                self._global_monitor = None  # kept as None; _remove_key_monitors() handles it safely
                self._local_monitor = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
                    _NSKeyDownMask, _local_key_handler
                )
                log_info("_do_show_interactive: local key monitor installed, popup ready")
            except Exception as e:
                log_exception(f"[preview_panel] _do_show_interactive error: {e}")
                self._remove_key_monitors()  # ensure no dangling monitors on partial setup failure

        queue.put((_do_show_interactive, (), {}))

    def append_text(self, text, queue):
        """Appends text to the interactive text_view (append-mode recording)."""
        def _do_append():
            if not self.panel or not self._is_interactive or not self.text_view:
                return
            current = str(self.text_view.string()).strip()
            new_text = (current + " " + text).strip() if current else text
            self._set_text_view_text(new_text)
            end = len(new_text)
            self.text_view.setSelectedRange_((end, 0))
        queue.put((_do_append, (), {}))

    def update_status(self, title, queue):
        def _do_update_status():
            if not self.panel:
                return
            if self._is_interactive:
                return
            self.title_field.setStringValue_(title)
            self.panel.animator().setAlphaValue_(0.9)

        queue.put((_do_update_status, (), {}))

    def update_text(self, text, queue):
        display = text
        if len(display) > 300:
            display = "… " + display[-290:]

        def _do_update():
            if not self.panel:
                return
            if self.text_field:
                self.text_field.setStringValue_(display)

        queue.put((_do_update, (), {}))

    def hide(self, queue, delay=0.8):
        def _do_hide():
            if not self.panel:
                return
            if self._is_interactive:
                # Properly close the interactive popup (not just hide): remove key
                # monitors and close the panel so state is fully reset.
                self._remove_key_monitors()
                self.panel.close()
                self.panel = None
                self.text_view = None
                self.scroll_view = None
                self._is_interactive = False
                return
            else:
                current_title = str(self.title_field.stringValue())
                if "✅" not in current_title and "Готово" not in current_title and "Ready" not in current_title:
                    if current_title:
                        self.title_field.setStringValue_("✅ " + current_title)

        queue.put((_do_hide, (), {}))

        def _delayed_fade_out():
            time.sleep(delay)
            def _fade_out():
                if self.panel:
                    self.panel.animator().setAlphaValue_(0.0)
            queue.put((_fade_out, (), {}))

        threading.Thread(target=_delayed_fade_out, daemon=True).start()
