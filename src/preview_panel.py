import threading
import time
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
)
from .utils import get_menu_icon_path

class TranscriptionPreviewPanel:
    def __init__(self):
        self.panel = None
        self.title_field = None
        self.text_field = None
        self.icon_view = None

    def _create_panel(self):
        if self.panel is not None:
            return

        # Width default 350, height default 100
        width = 350
        height = 100
        
        # Top-right corner offset
        margin_right = 40
        margin_top = 40
        
        # Get screen rect
        screen = NSScreen.mainScreen()
        frame = screen.visibleFrame()
        
        # Correctly position to top right of the current screen
        x = frame.origin.x + frame.size.width - width - margin_right
        y = frame.origin.y + frame.size.height - height - margin_top
        
        rect = NSRect(NSPoint(x, y), NSSize(width, height))
        
        # Create Panel
        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            rect,
            NSNonactivatingPanelMask | NSBorderlessWindowMask,
            2, # NSBackingStoreBuffered
            False
        )
        self.panel.setLevel_(NSFloatingWindowLevel)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setHasShadow_(True)
        # Ignore mouse events so it's transparent to clicks
        self.panel.setIgnoresMouseEvents_(True)
        
        # Visual Effect View
        visual_effect = NSVisualEffectView.alloc().initWithFrame_(NSRect(NSPoint(0, 0), NSSize(width, height)))
        visual_effect.setMaterial_(NSVisualEffectMaterialHUDWindow)
        visual_effect.setBlendingMode_(0) # NSVisualEffectBlendingModeBehindWindow
        visual_effect.setState_(1) # NSVisualEffectStateActive
        
        # Rounded corners
        visual_effect.setWantsLayer_(True)
        visual_effect.layer().setCornerRadius_(12.0)
        
        # Icon View (Top Left of the panel)
        icon_path = str(get_menu_icon_path())
        image = NSImage.alloc().initWithContentsOfFile_(icon_path)
        
        icon_size = 20
        icon_x = 15
        icon_y = height - 15 - icon_size # Top is at y=height
        self.icon_view = NSImageView.alloc().initWithFrame_(NSRect(NSPoint(icon_x, icon_y), NSSize(icon_size, icon_size)))
        if image:
            self.icon_view.setImage_(image)
            
        visual_effect.addSubview_(self.icon_view)
        
        # Title Field (Right next to icon)
        title_x = icon_x + icon_size + 10
        title_y = height - 15 - 18
        self.title_field = NSTextField.alloc().initWithFrame_(NSRect(NSPoint(title_x, title_y), NSSize(width - title_x - 15, 20)))
        self.title_field.setEditable_(False)
        self.title_field.setBordered_(False)
        self.title_field.setBackgroundColor_(NSColor.clearColor())
        self.title_field.setTextColor_(NSColor.whiteColor())
        self.title_field.setFont_(NSFont.boldSystemFontOfSize_(13.0))
        self.title_field.setAlignment_(NSTextAlignmentLeft)
        # Wrap title text nicely
        self.title_field.cell().setTruncatesLastVisibleLine_(True)
        self.title_field.cell().setLineBreakMode_(0) 
        
        visual_effect.addSubview_(self.title_field)
        
        # Main Text Field (Below title and icon)
        text_y_padding = 10
        text_height = title_y - text_y_padding
        self.text_field = NSTextField.alloc().initWithFrame_(NSRect(NSPoint(15, text_y_padding), NSSize(width - 30, text_height)))
        self.text_field.setEditable_(False)
        self.text_field.setBordered_(False)
        self.text_field.setBackgroundColor_(NSColor.clearColor())
        # Make the generic text slightly dimmed
        self.text_field.setTextColor_(NSColor.colorWithWhite_alpha_(1.0, 0.8))
        self.text_field.setFont_(NSFont.systemFontOfSize_(14.0))
        self.text_field.setAlignment_(NSTextAlignmentLeft)
        
        # Wrap text
        self.text_field.cell().setTruncatesLastVisibleLine_(True)
        self.text_field.cell().setLineBreakMode_(0) # NSLineBreakByWordWrapping
        self.text_field.setMaximumNumberOfLines_(3)
        
        visual_effect.addSubview_(self.text_field)
        self.panel.setContentView_(visual_effect)
        self.panel.setAlphaValue_(0.0)

    def show(self, title, queue):
        def _do_show():
            self._create_panel()
            self.title_field.setStringValue_(title)
            self.text_field.setStringValue_("")
            self.panel.orderFront_(None)
            self.panel.animator().setAlphaValue_(0.9)
            
        queue.put((_do_show, (), {}))

    def update_status(self, title, queue):
        def _do_update_status():
            if not self.panel:
                return
            self.title_field.setStringValue_(title)
            self.panel.animator().setAlphaValue_(0.9) # Ensure it's visible if hidden
            
        queue.put((_do_update_status, (), {}))

    def update_text(self, text, queue):
        # Pre-truncate BEFORE the closure to avoid rebinding the captured variable
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
