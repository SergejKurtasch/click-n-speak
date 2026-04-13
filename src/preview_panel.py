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
)
from .utils import get_menu_icon_path

class KeyablePanel(NSPanel):
    def canBecomeKeyWindow(self):
        return True

class TextFieldDelegate(NSObject):
    def init(self):
        self = objc.super(TextFieldDelegate, self).init()
        self.on_confirm = None
        return self

    def control_textView_doCommandBySelector_(self, control, text_view, command_selector):
        # convert the selector to string explicitly (e.g. 'insertNewline:')
        selector_str = str(command_selector)
        if selector_str == "insertNewline:":
            if self.on_confirm:
                # Get the uncommitted editing text directly from the textView
                self.on_confirm(str(text_view.string()))
            return True
        return False

class TranscriptionPreviewPanel:
    def __init__(self):
        self.panel = None
        self.title_field = None
        self.text_field = None
        self.icon_view = None
        self._delegate = None
        self._is_interactive = False

    def _update_position(self):
        if not self.panel:
            return
            
        width = self.panel.frame().size.width
        height = self.panel.frame().size.height
        
        mouse_loc = NSEvent.mouseLocation()
        x = mouse_loc.x - (width / 2)
        y = mouse_loc.y - height - 20 # Below the cursor
        
        # Ensure it's on screen
        screen = NSScreen.mainScreen()
        frame = screen.visibleFrame()
        if x < frame.origin.x: 
            x = frame.origin.x
        elif x + width > frame.origin.x + frame.size.width:
            x = frame.origin.x + frame.size.width - width
            
        if y < frame.origin.y:
            y = frame.origin.y
            
        self.panel.setFrameOrigin_(NSPoint(x, y))

    def _create_panel(self, interactive=False):
        # Recreate if mode changed
        if self.panel is not None:
            if self._is_interactive != interactive:
                self.panel.close()
                self.panel = None
            else:
                return

        width = 400
        height = 120
        
        mouse_loc = NSEvent.mouseLocation()
        x = mouse_loc.x - (width / 2)
        y = mouse_loc.y - height - 20
        
        screen = NSScreen.mainScreen()
        frame = screen.visibleFrame()
        if x < frame.origin.x: x = frame.origin.x
        elif x + width > frame.origin.x + frame.size.width: x = frame.origin.x + frame.size.width - width
        if y < frame.origin.y: y = frame.origin.y
            
        rect = NSRect(NSPoint(x, y), NSSize(width, height))
        
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
        
        icon_path = str(get_menu_icon_path())
        image = NSImage.alloc().initWithContentsOfFile_(icon_path)
        icon_size = 20
        icon_x = 15
        icon_y = height - 15 - icon_size
        self.icon_view = NSImageView.alloc().initWithFrame_(NSRect(NSPoint(icon_x, icon_y), NSSize(icon_size, icon_size)))
        if image:
            self.icon_view.setImage_(image)
            
        visual_effect.addSubview_(self.icon_view)
        
        title_x = icon_x + icon_size + 10
        title_y = height - 15 - 18
        self.title_field = NSTextField.alloc().initWithFrame_(NSRect(NSPoint(title_x, title_y), NSSize(width - title_x - 15, 20)))
        self.title_field.setEditable_(False)
        self.title_field.setBordered_(False)
        self.title_field.setBackgroundColor_(NSColor.clearColor())
        self.title_field.setTextColor_(NSColor.whiteColor())
        self.title_field.setFont_(NSFont.boldSystemFontOfSize_(13.0))
        self.title_field.setAlignment_(NSTextAlignmentLeft)
        self.title_field.cell().setTruncatesLastVisibleLine_(True)
        self.title_field.cell().setLineBreakMode_(0) 
        
        visual_effect.addSubview_(self.title_field)
        
        text_y_padding = 10
        text_height = title_y - text_y_padding
        self.text_field = NSTextField.alloc().initWithFrame_(NSRect(NSPoint(15, text_y_padding), NSSize(width - 30, text_height)))
        self.text_field.setBordered_(False)
        self.text_field.setBackgroundColor_(NSColor.clearColor())
        
        if interactive:
            self.text_field.setTextColor_(NSColor.whiteColor())
            self.text_field.setEditable_(True)
            self.text_field.setSelectable_(True)
            self.text_field.setDrawsBackground_(True)
            self.text_field.setBackgroundColor_(NSColor.colorWithWhite_alpha_(1.0, 0.1))
            self.text_field.cell().setWraps_(True)
            self.text_field.cell().setScrollable_(True)
            # Focus border
            self.text_field.setFocusRingType_(1) # NSFocusRingTypeExterior
            
            self._delegate = TextFieldDelegate.alloc().init()
            self.text_field.setDelegate_(self._delegate)
        else:
            self.text_field.setEditable_(False)
            self.text_field.setTextColor_(NSColor.colorWithWhite_alpha_(1.0, 0.8))
            self.text_field.cell().setTruncatesLastVisibleLine_(True)
            self.text_field.cell().setLineBreakMode_(0)
            self.text_field.setMaximumNumberOfLines_(3)
            
        self.text_field.setFont_(NSFont.systemFontOfSize_(14.0))
        self.text_field.setAlignment_(NSTextAlignmentLeft)
        
        visual_effect.addSubview_(self.text_field)
        self.panel.setContentView_(visual_effect)
        self.panel.setAlphaValue_(0.0)
        self._is_interactive = interactive

    def show(self, title, queue):
        def _do_show():
            self._create_panel(interactive=False)
            self._update_position()
            self.title_field.setStringValue_(title)
            self.text_field.setStringValue_("")
            self.panel.orderFront_(None)
            self.panel.animator().setAlphaValue_(0.9)
            
        queue.put((_do_show, (), {}))
        
    def show_interactive(self, text, queue, on_confirm):
        """Shows the panel in interactive mode under the cursor."""
        def _handle_confirm(new_text):
            self.hide(queue, delay=0)
            if on_confirm:
                on_confirm(new_text)

        def _do_show_interactive():
            self._create_panel(interactive=True)
            self._update_position()
            self._delegate.on_confirm = _handle_confirm
            
            # Help user know what to do
            self.title_field.setStringValue_("Edit and press Enter")
            self.text_field.setStringValue_(text)
            
            self.panel.makeKeyAndOrderFront_(None)
            self.panel.animator().setAlphaValue_(0.9)
            
            # Put focus into our text field
            self.panel.makeFirstResponder_(self.text_field)
            
        queue.put((_do_show_interactive, (), {}))

    def update_status(self, title, queue):
        def _do_update_status():
            if not self.panel:
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
            self.text_field.setStringValue_(display)

        queue.put((_do_update, (), {}))

    def hide(self, queue, delay=0.8):
        def _do_hide():
            if not self.panel:
                return
            current_title = str(self.title_field.stringValue())
            if "✅" not in current_title and "Готово" not in current_title and "Ready" not in current_title and "Edit" not in current_title:
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


