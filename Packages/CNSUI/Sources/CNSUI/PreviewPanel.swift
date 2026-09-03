import AppKit
import CNSCore

/// HUD popup (NSPanel) near the cursor, in two modes.
///
/// Non-interactive: live status + streaming text while dictating. Interactive:
/// an editable NSTextView where the user fixes the transcription and presses
/// Enter. Ported from `preview_panel.py`; per SWIFT_MIGRATION_PLAN.md §4.2 every
/// method runs on the main actor directly, replacing the Python `_main_thread_queue`.
///
/// The panel is non-activating, so Enter/Escape/⌘D arrive through an
/// `NSEvent` local monitor rather than the responder chain.
@MainActor
public final class PreviewPanel: PopupPresenting {
    private let width: CGFloat = 400
    private var height: CGFloat { isInteractive ? 160 : 120 }

    private let resources: AppResources
    private let i18n: I18n
    private let log: @Sendable (String) -> Void

    private var panel: NSPanel?
    private var titleField: NSTextField?
    private var textField: NSTextField?      // non-interactive mode only
    private var textView: DictionaryAwareTextView?  // interactive mode only
    private var scrollView: NSScrollView?
    private var fadeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    private var isInteractive = false
    /// True between `showInteractive` and the confirm/cancel that ends it. Guards
    /// against confirm and cancel both firing for one keypress.
    private var awaitingDecision = false
    /// AppKit monitor tokens are opaque/non-Sendable. All mutations occur on
    /// the main actor; `nonisolated(unsafe)` only lets deinit unregister it.
    nonisolated(unsafe) private var keyMonitor: Any?
    private var canonicalTitle = ""

    private var onConfirm: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var onAddToDictionary: ((String) -> AddTermResult)?
    private var toasts = DictionaryToasts()

    public init(
        resources: AppResources,
        i18n: I18n? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.resources = resources
        self.i18n = i18n ?? I18n.load("en", localesDirectory: resources.localesDirectory)
        self.log = log
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        fadeTask?.cancel()
        toastTask?.cancel()
    }

    /// Whether the editable popup is currently open and waiting on the user.
    public var isShowingInteractive: Bool { awaitingDecision }

    /// Text currently in the editor, or nil when the popup is not interactive.
    public var currentText: String? { textView?.string }

    /// Test seams: the editor and title are otherwise private to the panel.
    var titleForTesting: String? { titleField?.stringValue }
    var isVisibleForTesting: Bool { panel?.isVisible ?? false }
    var editorAccessibilityIdentifierForTesting: String? {
        textView?.accessibilityIdentifier()
    }

    func setSelectionForTesting(_ range: NSRange) {
        textView?.setSelectedRange(range)
    }

    // MARK: - Non-interactive HUD

    /// Show the HUD with `title`, positioned just below the cursor, fading in.
    public func show(title: String) {
        let panel = makePanel(interactive: false)
        canonicalTitle = title
        panel.setAccessibilityLabel(title)
        titleField?.stringValue = title
        textField?.stringValue = ""
        position(panel)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 0.9 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0.9
            }
        }
    }

    /// Update the status title (`update_status`). Ignored while the user is
    /// editing — the title there belongs to the popup's own instructions.
    public func updateStatus(_ title: String) {
        guard let panel, !isInteractive else { return }
        canonicalTitle = title
        panel.setAccessibilityLabel(i18n.t("preview.editor_accessibility"))
        titleField?.stringValue = title
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0.9
        } else {
            panel.animator().alphaValue = 0.9
        }
    }

    /// Update the body text, truncating to the last ~290 chars like the Python
    /// `update_text` (keeps the most recent speech visible).
    public func updateText(_ text: String) {
        guard panel != nil, let textField else { return }
        var display = text
        if display.count > 300 {
            display = "… " + String(display.suffix(290))
        }
        textField.stringValue = display
    }

    // MARK: - Interactive popup

    /// Open the editable popup over `text`. Exactly one of `onConfirm` /
    /// `onCancel` fires, once.
    public func showInteractive(
        text: String,
        title: String,
        toasts: DictionaryToasts = DictionaryToasts(),
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void = {},
        onAddToDictionary: ((String) -> AddTermResult)? = nil
    ) {
        removeKeyMonitor()  // any leftover from a previous session
        let panel = makePanel(interactive: true)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onAddToDictionary = onAddToDictionary
        self.toasts = toasts
        self.awaitingDecision = true

        canonicalTitle = title
        titleField?.stringValue = title
        titleField?.textColor = .white
        setEditorText(text)

        position(panel)
        panel.orderFrontRegardless()
        panel.alphaValue = 0.9

        // A menu-bar-only app is never "active", so without this the panel shows
        // but receives no keystrokes. Focus is handed back in the injection path.
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKey()
        if let textView {
            panel.makeFirstResponder(textView)
            textView.selectAll(nil)
        }

        installKeyMonitor()
        log("Interactive popup shown (chars=\(text.count))")
    }

    /// Append newly dictated text to the open editor (append-to-popup mode).
    public func appendText(_ text: String) {
        guard panel != nil, isInteractive, let textView else { return }
        let current = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = current.isEmpty
            ? text
            : (current + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)
        setEditorText(combined)
        textView.setSelectedRange(NSRange(location: (combined as NSString).length, length: 0))
    }

    /// Add the selection (or the word under the caret) to the dictionary, showing
    /// the outcome as a short toast in the title.
    public func addSelectionToDictionary() {
        guard let textView else { return }
        let full = textView.string
        let selected = textView.selectedRange()
        let candidate: String
        if selected.length > 0, selected.location < (full as NSString).length {
            candidate = (full as NSString)
                .substring(with: selected)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = TermParsing
                .wordAtOffset(full, utf16Offset: selected.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard TermParsing.isValidTerm(candidate), let onAddToDictionary else {
            flashToast(toasts.invalidTerm)
            return
        }

        switch onAddToDictionary(candidate) {
        case .added(let message):
            flashToast(message ?? toasts.addedTemplate.replacingOccurrences(of: "{term}", with: candidate))
        case .alreadyExists:
            flashToast(toasts.alreadyExists)
        }
    }

    // MARK: - Hide / close

    /// Mark the title done and fade out after `delay` seconds (`hide`). An open
    /// interactive popup is closed outright instead — its state must fully reset.
    public func hide(delay: TimeInterval = 0.8) {
        guard let panel else { return }
        if isInteractive {
            teardownInteractive()
            return
        }
        if let titleField {
            let current = titleField.stringValue
            if !current.isEmpty, !current.contains("✅"), !current.contains("Готово"), !current.contains("Ready") {
                titleField.stringValue = "✅ " + current
            }
        }
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.panel === panel, !self.isInteractive else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.alphaValue = 0
                panel.orderOut(nil)
            } else {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0.15
                panel.animator().alphaValue = 0
                NSAnimationContext.endGrouping()
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, self.panel === panel, !self.isInteractive else { return }
                panel.orderOut(nil)
            }
        }
    }

    public func close() {
        fadeTask?.cancel()
        toastTask?.cancel()
        removeKeyMonitor()
        panel?.close()
        panel = nil
        titleField = nil
        textField = nil
        textView = nil
        scrollView = nil
        awaitingDecision = false
        isInteractive = false
    }

    // MARK: - Confirm / cancel

    /// Internal so the key monitor and the text view can both route here; the
    /// `awaitingDecision` flag makes the first call win.
    func confirm() {
        guard awaitingDecision else { return }
        awaitingDecision = false
        let text = (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let handler = onConfirm
        teardownInteractive()
        log("Popup confirmed with text len=\(text.count)")
        handler?(text)
    }

    func cancel() {
        guard awaitingDecision else { return }
        awaitingDecision = false
        let handler = onCancel
        teardownInteractive()
        log("Popup cancelled")
        handler?()
    }

    private func teardownInteractive() {
        removeKeyMonitor()
        toastTask?.cancel()
        // Close and drop the panel so the next non-interactive show() builds a
        // fresh one in the right layout.
        panel?.close()
        panel = nil
        titleField = nil
        textField = nil
        textView = nil
        scrollView = nil
        isInteractive = false
        awaitingDecision = false
        onConfirm = nil
        onCancel = nil
        onAddToDictionary = nil
    }

    // MARK: - Key monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // The monitor always fires on the main thread; NSEvent is not Sendable,
            // so only the Bool verdict crosses the isolation boundary.
            let consumed = MainActor.assumeIsolated {
                self.handleKey(keyCode: Int(event.keyCode),
                               hasCommand: event.modifierFlags.contains(.command),
                               characters: event.charactersIgnoringModifiers)
            }
            return consumed ? nil : event
        }
    }

    /// Returns true when the event was handled and must not travel further —
    /// Enter reaching the app behind the popup would fire whatever it focuses.
    func handleKey(keyCode: Int, hasCommand: Bool, characters: String?) -> Bool {
        guard awaitingDecision else { return false }
        switch keyCode {
        case Self.keyReturn, Self.keyEnter:
            confirm()
            return true
        case Self.keyEscape:
            cancel()
            return true
        default:
            break
        }
        if hasCommand, characters?.lowercased() == "d" {
            addSelectionToDictionary()
            return true
        }
        return false
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private static let keyReturn = 36
    private static let keyEnter = 76  // numpad
    private static let keyEscape = 53

    // MARK: - Toast

    private func flashToast(_ message: String, duration: TimeInterval = 1.5) {
        guard let titleField else { return }
        let restoreTo = canonicalTitle
        titleField.stringValue = message
        titleField.textColor = .systemGreen

        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let field = self?.titleField else { return }
            field.stringValue = restoreTo
            field.textColor = .white
        }
    }

    // MARK: - Construction

    private func makePanel(interactive: Bool) -> NSPanel {
        if let panel {
            if isInteractive == interactive { return panel }
            // Layouts differ; rebuild rather than reshuffle subviews.
            removeKeyMonitor()
            panel.close()
            self.panel = nil
            titleField = nil
            textField = nil
            textView = nil
            scrollView = nil
        }
        isInteractive = interactive

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let panel = KeyablePanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = !interactive
        panel.setAccessibilityLabel(interactive
            ? i18n.t("preview.editor_accessibility")
            : canonicalTitle)

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
        iconView.setAccessibilityElement(false)
        effect.addSubview(iconView)

        let titleX = iconX + iconSize + 10
        let titleY = height - 15 - 18
        let title = NSTextField(frame: NSRect(x: titleX, y: titleY, width: width - titleX - 15, height: 20))
        configureLabel(title, color: .white, font: .boldSystemFont(ofSize: 13))
        title.setAccessibilityIdentifier("preview.status")
        effect.addSubview(title)
        self.titleField = title

        let textBottomPad: CGFloat = 10
        let titleGap: CGFloat = 10
        let textH = titleY - textBottomPad - titleGap
        let textW = width - 30

        if interactive {
            let scroll = NSScrollView(frame: NSRect(x: 15, y: textBottomPad, width: textW, height: textH))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = false
            scroll.borderType = .noBorder
            scroll.drawsBackground = true
            scroll.backgroundColor = NSColor(white: 1.0, alpha: 0.08)
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 6

            let contentSize = scroll.contentSize
            let editor = DictionaryAwareTextView(
                frame: NSRect(origin: .zero, size: contentSize)
            )
            editor.minSize = contentSize
            editor.maxSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.textContainer?.containerSize = NSSize(
                width: contentSize.width,
                height: .greatestFiniteMagnitude
            )
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.lineFragmentPadding = 4
            editor.textColor = .white
            editor.font = .systemFont(ofSize: 14)
            editor.isEditable = true
            editor.isSelectable = true
            editor.drawsBackground = false
            editor.insertionPointColor = .white
            editor.isRichText = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.addToDictionaryTitle = i18n.t("preview.add_dictionary")
            editor.onAddToDictionary = { [weak self] in self?.addSelectionToDictionary() }
            editor.setAccessibilityLabel(i18n.t("preview.editor_accessibility"))
            editor.setAccessibilityHelp(i18n.t("preview.editor_help"))
            editor.setAccessibilityIdentifier("preview.editor")

            scroll.documentView = editor
            effect.addSubview(scroll)
            self.scrollView = scroll
            self.textView = editor
            self.textField = nil
        } else {
            let text = NSTextField(frame: NSRect(x: 15, y: textBottomPad, width: textW, height: textH))
            configureLabel(text, color: NSColor(white: 1.0, alpha: 0.8), font: .systemFont(ofSize: 14))
            text.setAccessibilityIdentifier("preview.live-text")
            text.maximumNumberOfLines = 3
            text.cell?.wraps = true
            effect.addSubview(text)
            self.textField = text
            self.textView = nil
            self.scrollView = nil
        }

        panel.contentView = effect
        panel.alphaValue = 0
        self.panel = panel
        return panel
    }

    /// Set the editor's text keeping the white-on-HUD attributes.
    private func setEditorText(_ text: String) {
        guard let textView else { return }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14),
            ]
        )
        textView.textStorage?.setAttributedString(attributed)
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
        panel.setFrameOrigin(PopupPlacement.origin(
            mouse: mouse,
            panelSize: panel.frame.size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        ))
    }
}

/// A borderless non-activating panel refuses key status by default, which would
/// leave the editor unable to receive typing.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
