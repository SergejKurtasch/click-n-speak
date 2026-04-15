import threading
import time
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
)
from Foundation import NSAttributedString
from .utils import get_menu_icon_path, log_info

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

_NSKeyDownMask = 1 << 10   # NSEventMaskKeyDown
_KEY_RETURN  = 36
_KEY_ENTER   = 76  # numpad Enter
_KEY_ESCAPE  = 53

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
            self.text_view = NSTextView.alloc().initWithFrame_(tv_rect)
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
        from AppKit import NSForegroundColorAttributeName, NSFontAttributeName
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
            self.text_field.setStringValue_("")
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

    def show_interactive(self, text, queue, on_confirm, on_cancel=None, title="Редактируй и нажми Enter"):
        """Shows the panel in interactive mode near the cursor."""
        def _handle_confirm(new_text):
            if not self._is_interactive:
                return  # already handled (guard against double-fire)
            new_text = new_text.strip()
            self._remove_key_monitors()
            if self.panel:
                self.panel.orderOut_(None)
            self._is_interactive = False
            log_info(f"_handle_confirm: confirming with text len={len(new_text)}")
            if on_confirm:
                try:
                    on_confirm(new_text)
                except Exception as e:
                    import traceback
                    print(f"[preview_panel] on_confirm error: {e}\n{traceback.format_exc()}")

        def _handle_cancel():
            if not self._is_interactive:
                return
            self._remove_key_monitors()
            if self.panel:
                self.panel.orderOut_(None)
            self._is_interactive = False
            log_info("_handle_cancel: popup cancelled")
            if on_cancel:
                try:
                    on_cancel()
                except Exception as e:
                    import traceback
                    print(f"[preview_panel] on_cancel error: {e}\n{traceback.format_exc()}")

        def _do_show_interactive():
            try:
                log_info("_do_show_interactive: starting")
                self._remove_key_monitors()
                self._create_panel(interactive=True)
                log_info(f"_do_show_interactive: panel created, panel={self.panel is not None}")
                self._update_position(center=False)
                self._delegate.on_confirm = _handle_confirm
                self._delegate.on_cancel = _handle_cancel

                self.title_field.setStringValue_(title)
                self._set_text_view_text(text)

                # Show the window (orderFrontRegardless bypasses app-active requirement).
                self.panel.orderFrontRegardless()
                self.panel.setAlphaValue_(0.9)

                # Try to make the panel key so the local monitor (which CAN consume
                # events) gets Enter/Escape instead of the global one (which cannot).
                # makeKeyWindow() works here because KeyablePanel.canBecomeKeyWindow
                # returns True and NSNonactivatingPanelMask only prevents AUTOMATIC
                # key-window acquisition — explicit calls still work.
                self.panel.makeKeyWindow()
                self.panel.makeFirstResponder_(self.text_view)
                self.text_view.selectAll_(None)

                log_info(
                    f"_do_show_interactive: isVisible={self.panel.isVisible()}, "
                    f"isKeyWindow={self.panel.isKeyWindow()}, "
                    f"alpha={self.panel.alphaValue():.2f}"
                )

                # Install key monitors so Enter/Escape work regardless of whether the
                # panel actually received keyboard focus.
                # Local monitor  = our app is key → can consume the event (return None).
                # Global monitor = other app is key → observe only, cannot consume.
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
                    return event

                def _global_key_handler(event):
                    if not self._is_interactive:
                        return
                    kc = event.keyCode()
                    log_info(f"global_key_handler: keyCode={kc}")
                    if kc in (_KEY_RETURN, _KEY_ENTER):
                        txt = str(self.text_view.string()).strip() if self.text_view else ""
                        _handle_confirm(txt)
                    elif kc == _KEY_ESCAPE:
                        _handle_cancel()

                self._local_monitor = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
                    _NSKeyDownMask, _local_key_handler
                )
                self._global_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
                    _NSKeyDownMask, _global_key_handler
                )
                log_info("_do_show_interactive: key monitors installed, popup ready")
            except Exception as e:
                import traceback
                print(f"[preview_panel] _do_show_interactive error: {e}\n{traceback.format_exc()}")

        queue.put((_do_show_interactive, (), {}))

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
                self._is_interactive = False
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
