import AppKit

/// Non-interactive HUD popup (NSPanel) that shows live transcription status and
/// text near the cursor without stealing focus. Ported from the non-interactive
/// path of `preview_panel.py` (`_create_panel(interactive=False)`, `show`,
/// `update_status`, `update_text`, `hide`). The interactive editing mode
/// (NSTextView, ⌘D Add to Dictionary, Enter/Escape) lands in Phase 3.
///
/// Per SWIFT_MIGRATION_PLAN.md §4.2 all methods run on the main actor directly,
/// replacing the Python `_main_thread_queue` hops.
@MainActor
public final class PreviewPanel {
    private let width: CGFloat = 400
    private let height: CGFloat = 120

    private let resources: AppResources
    private var panel: NSPanel?
    private var titleField: NSTextField?
    private var textField: NSTextField?
    private var fadeTask: Task<Void, Never>?

    public init(resources: AppResources) {
        self.resources = resources
    }

    /// Show the HUD with `title`, positioned just below the cursor, fading in.
    public func show(title: String) {
        let panel = createPanelIfNeeded()
        titleField?.stringValue = title
        textField?.stringValue = ""
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0.9
        }
    }

    /// Update the status title (`update_status`).
    public func updateStatus(_ title: String) {
        guard let panel else { return }
        titleField?.stringValue = title
        panel.animator().alphaValue = 0.9
    }

    /// Update the body text, truncating to the last ~290 chars like the Python
    /// `update_text` (keeps the most recent speech visible).
    public func updateText(_ text: String) {
        guard panel != nil else { return }
        var display = text
        if display.count > 300 {
            display = "… " + String(display.suffix(290))
        }
        textField?.stringValue = display
    }

    /// Mark the title done and fade out after `delay` seconds (`hide`).
    public func hide(delay: TimeInterval = 0.8) {
        guard let titleField else { return }
        let current = titleField.stringValue
        if !current.isEmpty, !current.contains("✅"), !current.contains("Готово"), !current.contains("Ready") {
            titleField.stringValue = "✅ " + current
        }
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel?.animator().alphaValue = 0
        }
    }

    public func close() {
        fadeTask?.cancel()
        panel?.close()
        panel = nil
        titleField = nil
        textField = nil
    }

    // MARK: - Construction

    private func createPanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: rect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12

        let iconSize: CGFloat = 20
        let iconX: CGFloat = 15
        let iconY = height - 15 - iconSize
        let iconView = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
        iconView.image = resources.appIcon()
        effect.addSubview(iconView)

        let titleX = iconX + iconSize + 10
        let titleY = height - 15 - 18
        let title = NSTextField(frame: NSRect(x: titleX, y: titleY, width: width - titleX - 15, height: 20))
        configureLabel(title, color: .white, font: .boldSystemFont(ofSize: 13))
        effect.addSubview(title)
        self.titleField = title

        let textBottomPad: CGFloat = 10
        let titleGap: CGFloat = 10
        let textH = titleY - textBottomPad - titleGap
        let text = NSTextField(frame: NSRect(x: 15, y: textBottomPad, width: width - 30, height: textH))
        configureLabel(text, color: NSColor(white: 1.0, alpha: 0.8), font: .systemFont(ofSize: 14))
        text.maximumNumberOfLines = 3
        text.cell?.wraps = true
        effect.addSubview(text)
        self.textField = text

        panel.contentView = effect
        panel.alphaValue = 0
        self.panel = panel
        return panel
    }

    private func configureLabel(_ field: NSTextField, color: NSColor, font: NSFont) {
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.textColor = color
        field.font = font
        field.alignment = .left
        field.cell?.truncatesLastVisibleLine = true
        field.lineBreakMode = .byWordWrapping
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        var x = mouse.x - width / 2
        var y = mouse.y - height - 20
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            if x < frame.origin.x { x = frame.origin.x }
            else if x + width > frame.origin.x + frame.size.width { x = frame.origin.x + frame.size.width - width }
            if y < frame.origin.y { y = frame.origin.y }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
