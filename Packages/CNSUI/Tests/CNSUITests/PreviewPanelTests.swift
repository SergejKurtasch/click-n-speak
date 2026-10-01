import AppKit
import Foundation
import Testing
@testable import CNSCore
@testable import CNSUI

@MainActor
@Suite("Interactive preview panel")
struct PreviewPanelTests {
    private func repoResources() -> AppResources {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("locales").path) {
                return AppResources(
                    localesDirectory: dir.appendingPathComponent("locales"),
                    iconsDirectory: dir.appendingPathComponent("assets/icons")
                )
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("Could not locate repo locales/ from \(#filePath)")
    }

    private func makePanel() -> PreviewPanel {
        PreviewPanel(resources: repoResources())
    }

    private let keyReturn = 36
    private let keyEscape = 53

    @Test("Enter confirms with the edited text")
    func enterConfirms() {
        let panel = makePanel()
        var confirmed: String?
        var cancelled = false

        panel.showInteractive(
            text: "распознанный текст",
            title: "Edit and press Enter",
            onConfirm: { confirmed = $0 },
            onCancel: { cancelled = true }
        )
        #expect(panel.isShowingInteractive == true)

        _ = panel.handleKey(keyCode: keyReturn, hasCommand: false, characters: "\r")

        #expect(confirmed == "распознанный текст")
        #expect(cancelled == false)
        #expect(panel.isShowingInteractive == false)
        panel.close()
    }

    @Test("Escape cancels without confirming")
    func escapeCancels() {
        let panel = makePanel()
        var confirmed: String?
        var cancelled = false

        panel.showInteractive(
            text: "текст",
            title: "Edit",
            onConfirm: { confirmed = $0 },
            onCancel: { cancelled = true }
        )
        _ = panel.handleKey(keyCode: keyEscape, hasCommand: false, characters: nil)

        #expect(cancelled == true)
        #expect(confirmed == nil)
        panel.close()
    }

    @Test("Only the first decision counts")
    func decisionHappensOnce() {
        let panel = makePanel()
        var confirmCount = 0
        var cancelCount = 0

        panel.showInteractive(
            text: "текст",
            title: "Edit",
            onConfirm: { _ in confirmCount += 1 },
            onCancel: { cancelCount += 1 }
        )
        _ = panel.handleKey(keyCode: keyReturn, hasCommand: false, characters: "\r")
        _ = panel.handleKey(keyCode: keyReturn, hasCommand: false, characters: "\r")
        _ = panel.handleKey(keyCode: keyEscape, hasCommand: false, characters: nil)

        #expect(confirmCount == 1)
        #expect(cancelCount == 0)
        panel.close()
    }

    @Test("Disabled decisions preserve the editor and swallow Enter and Escape")
    func disabledDecisionsPreservePopup() {
        let panel = makePanel()
        var confirmCount = 0
        var cancelCount = 0
        panel.showInteractive(
            text: "editable draft",
            title: "Edit",
            onConfirm: { _ in confirmCount += 1 },
            onCancel: { cancelCount += 1 }
        )

        panel.setDecisionEnabled(false)
        #expect(panel.handleKey(keyCode: keyReturn, hasCommand: false, characters: "\r"))
        #expect(panel.handleKey(keyCode: keyEscape, hasCommand: false, characters: nil))
        #expect(panel.currentText == "editable draft")
        #expect(panel.isShowingInteractive)
        #expect(confirmCount == 0)
        #expect(cancelCount == 0)

        panel.setDecisionEnabled(true)
        _ = panel.handleKey(keyCode: keyReturn, hasCommand: false, characters: "\r")
        #expect(confirmCount == 1)
        panel.close()
    }

    @Test("Incomplete warning survives status updates without changing the draft")
    func incompleteWarningPreservesEditor() {
        let panel = makePanel()
        panel.showInteractive(
            text: "first third",
            title: "Edit",
            onConfirm: { _ in }
        )
        panel.setSelectionForTesting(NSRange(location: 5, length: 0))

        panel.showIncompleteWarning("Incomplete transcription")
        panel.updateStatus("Ready")

        #expect(panel.currentText == "first third")
        #expect(panel.selectionForTesting == NSRange(location: 5, length: 0))
        #expect(panel.incompleteWarningForTesting == "Incomplete transcription")
        #expect(panel.titleForTesting == "Incomplete transcription")
        #expect(panel.isShowingInteractive)
        panel.close()
    }

    @Test("Enter and Escape are swallowed; other keys pass through")
    func consumesOnlyItsOwnKeys() {
        let panel = makePanel()
        panel.showInteractive(text: "текст", title: "Edit", onConfirm: { _ in })

        #expect(panel.handleKey(keyCode: 0, hasCommand: false, characters: "a") == false)
        #expect(panel.handleKey(keyCode: keyReturn, hasCommand: false, characters: "\r") == true)
        // After the popup closed, keys are no longer ours to consume.
        #expect(panel.handleKey(keyCode: keyEscape, hasCommand: false, characters: nil) == false)
        panel.close()
    }

    @Test("Append adds to the existing text with a single space")
    func appendsText() {
        let panel = makePanel()
        var confirmed: String?
        panel.showInteractive(text: "первая часть", title: "Edit", onConfirm: { confirmed = $0 })

        panel.appendText("вторая часть")
        #expect(panel.currentText == "первая часть вторая часть")

        _ = panel.handleKey(keyCode: keyReturn, hasCommand: false, characters: "\r")
        #expect(confirmed == "первая часть вторая часть")
        panel.close()
    }

    @Test("⌘D sends the word under the caret to the dictionary")
    func addsWordUnderCaret() {
        let panel = makePanel()
        var added: [String] = []
        panel.showInteractive(
            text: "мы используем Whisper локально",
            title: "Edit",
            onConfirm: { _ in },
            onAddToDictionary: { term in
                added.append(term)
                return .added(message: nil)
            }
        )
        // Caret inside "Whisper".
        panel.setSelectionForTesting(NSRange(location: 15, length: 0))
        #expect(panel.handleKey(keyCode: 2, hasCommand: true, characters: "d") == true)

        #expect(added == ["Whisper"])
        panel.close()
    }

    @Test("⌘D on a selection sends the whole phrase")
    func addsSelectedPhrase() {
        let panel = makePanel()
        var added: [String] = []
        panel.showInteractive(
            text: "код-ревью это полезно",
            title: "Edit",
            onConfirm: { _ in },
            onAddToDictionary: { term in
                added.append(term)
                return .added(message: nil)
            }
        )
        panel.setSelectionForTesting(NSRange(location: 0, length: 9))  // "код-ревью"
        _ = panel.handleKey(keyCode: 2, hasCommand: true, characters: "d")

        #expect(added == ["код-ревью"])
        panel.close()
    }

    @Test("An invalid term never reaches the dictionary")
    func rejectsInvalidTerm() {
        let panel = makePanel()
        var added: [String] = []
        panel.showInteractive(
            text: "the 123",
            title: "Edit",
            onConfirm: { _ in },
            onAddToDictionary: { term in
                added.append(term)
                return .added(message: nil)
            }
        )
        panel.setSelectionForTesting(NSRange(location: 0, length: 3))  // "the" — stoplist
        _ = panel.handleKey(keyCode: 2, hasCommand: true, characters: "d")

        #expect(added.isEmpty)
        panel.close()
    }

    @Test("Switching from the HUD to the editor rebuilds the panel")
    func switchesModes() {
        let panel = makePanel()
        panel.show(title: "Recording")
        panel.updateText("живой текст")
        #expect(panel.currentText == "")  // HUD mode has no editor

        panel.showInteractive(text: "итог", title: "Edit", onConfirm: { _ in })
        #expect(panel.currentText == "итог")

        _ = panel.handleKey(keyCode: keyEscape, hasCommand: false, characters: nil)
        // Back to the HUD layout without a stale editor.
        panel.show(title: "Ready")
        #expect(panel.currentText == "")
        panel.close()
    }

    @Test("Status updates are ignored while the user is editing")
    func statusIgnoredWhileEditing() {
        let panel = makePanel()
        panel.showInteractive(text: "текст", title: "Edit and press Enter", onConfirm: { _ in })

        panel.updateStatus("Transcribing…")
        #expect(panel.titleForTesting == "Edit and press Enter")
        panel.close()
    }

    @Test("Popup placement uses the display containing the pointer and clamps every edge")
    func multiDisplayPlacement() {
        let left = NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let right = NSRect(x: 0, y: 24, width: 2_560, height: 1_416)
        let size = NSSize(width: 400, height: 160)

        let onLeft = PopupPlacement.origin(
            mouse: NSPoint(x: -1_900, y: 50),
            panelSize: size,
            visibleFrames: [right, left]
        )
        #expect(onLeft.x == left.minX)
        #expect(onLeft.y == left.minY)

        let onRight = PopupPlacement.origin(
            mouse: NSPoint(x: 2_550, y: 1_430),
            panelSize: size,
            visibleFrames: [left, right]
        )
        #expect(onRight.x == right.maxX - size.width)
        #expect(onRight.y + size.height <= right.maxY)
    }

    @Test("Short drafts stay compact while long drafts grow within display limits")
    func adaptiveEditorSize() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let short = PreviewPanelSizing.preferredSize(
            text: "Short draft.",
            visibleFrame: visibleFrame
        )
        let long = PreviewPanelSizing.preferredSize(
            text: String(repeating: "A longer dictated sentence with several words. ", count: 40),
            visibleFrame: visibleFrame
        )

        #expect(short.width < 400)
        #expect(short.height < 160)
        #expect(long.width > short.width)
        #expect(long.height > short.height)
        #expect(long.width <= 600)
        #expect(long.height <= visibleFrame.height * 0.52)
    }

    @Test("Explicit short lines grow height without needlessly widening the editor")
    func multilineEditorSize() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let short = PreviewPanelSizing.preferredSize(
            text: "Short draft.",
            visibleFrame: visibleFrame
        )
        let multiline = PreviewPanelSizing.preferredSize(
            text: Array(repeating: "short line", count: 12).joined(separator: "\n"),
            visibleFrame: visibleFrame
        )

        #expect(multiline.width == short.width)
        #expect(multiline.height > short.height)
    }

    @Test("Editor stays within the work area on a small display")
    func smallDisplayEditorSize() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let size = PreviewPanelSizing.preferredSize(
            text: String(repeating: "A long dictated sentence. ", count: 40),
            visibleFrame: visibleFrame
        )

        #expect(size.width <= visibleFrame.width - 24)
        #expect(size.height <= visibleFrame.height - 24)
        #expect(size.width <= 600)
    }

    @Test("Growing an open editor keeps its top edge stable and stays on screen")
    func resizedEditorPlacement() {
        let display = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let original = NSRect(x: 500, y: 600, width: 360, height: 132)
        let grown = PopupPlacement.originForResize(
            oldFrame: original,
            newSize: NSSize(width: 600, height: 300),
            visibleFrames: [display]
        )

        #expect(grown.x == 380)
        #expect(grown.y == 432)

        let edge = PopupPlacement.originForResize(
            oldFrame: NSRect(x: 5, y: 5, width: 360, height: 132),
            newSize: NSSize(width: 600, height: 480),
            visibleFrames: [display]
        )
        #expect(edge.x >= display.minX)
        #expect(edge.y >= display.minY)
    }

    @Test("Appending dictation enlarges the actual editor window")
    func appendResizesEditorWindow() {
        let panel = makePanel()
        let marker = "Adaptive draft marker"
        panel.showInteractive(text: marker, title: "Edit", onConfirm: { _ in })
        let before = editorWindow(containing: marker)?.frame

        panel.appendText(String(repeating: " more dictated words for this draft", count: 40))
        let after = editorWindow(containing: marker)?.frame

        #expect(before != nil)
        #expect(after != nil)
        if let before, let after {
            #expect(before.width < 400)
            #expect(before.height < 160)
            #expect(after.width > before.width)
            #expect(after.height > before.height)
        }
        if let window = editorWindow(containing: marker),
           let scroll = window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
           let editor = scroll.documentView as? DictionaryAwareTextView,
           let container = editor.textContainer {
            editor.layoutManager?.ensureLayout(for: container)
            let usedHeight = editor.layoutManager?.usedRect(for: container).height ?? 0
            #expect(container.containerSize.width == scroll.contentSize.width)
            #expect(editor.frame.height <= max(scroll.contentSize.height, usedHeight + 20))
        }
        panel.close()
    }

    @Test("Pending append is a separate read-only scrolling surface capped at 100 points")
    func pendingAppendSurface() {
        let panel = makePanel()
        let marker = "Pending surface draft"
        panel.showInteractive(text: marker, title: "Edit", onConfirm: { _ in })
        panel.setSelectionForTesting(NSRange(location: 7, length: 3))

        panel.showPendingAppend(
            String(repeating: "new wrapped words ", count: 80),
            title: "New recording · Refining…"
        )

        let window = editorWindow(containing: marker)
        let scrollViews = descendants(of: window?.contentView).compactMap { $0 as? NSScrollView }
        let pending = scrollViews.first { scroll in
            guard let textView = scroll.documentView as? NSTextView else { return false }
            return textView.string.contains("new wrapped words")
        }
        #expect(scrollViews.count == 2)
        #expect(pending != nil)
        #expect(pending?.hasVerticalScroller == true)
        #expect((pending?.frame.height ?? .infinity) <= 100)
        #expect((pending?.documentView as? NSTextView)?.isEditable == false)
        #expect((pending?.documentView as? NSTextView)?.textContainer?.widthTracksTextView == true)
        #expect((pending?.documentView as? NSTextView)?.string.contains("New recording · Refining…") == true)
        #expect(panel.currentText == marker)
        #expect(panel.selectionForTesting == NSRange(location: 7, length: 3))

        panel.clearPendingAppend()
        #expect(descendants(of: window?.contentView).compactMap { $0 as? NSScrollView }.count == 1)
        panel.close()
    }

    @Test("Compact pending layout keeps both editors below the title")
    func compactPendingLayoutFrames() throws {
        let panel = makePanel()
        let marker = "Short draft"
        panel.showInteractive(text: marker, title: "Edit", onConfirm: { _ in })
        panel.showPendingAppend("Short append", title: "New recording · Refining…")

        let window = try #require(editorWindow(containing: marker))
        let views = descendants(of: window.contentView)
        let title = try #require(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "preview.status"
        })
        let main = try #require(views.compactMap { $0 as? NSScrollView }.first {
            ($0.documentView as? DictionaryAwareTextView)?.string == marker
        })
        let pending = try #require(views.compactMap { $0 as? NSScrollView }.first {
            ($0.documentView as? NSTextView)?.string.contains("Short append") == true
        })

        #expect(pending.frame.height <= 100)
        #expect(main.frame.height >= 44)
        #expect(pending.frame.maxY + 6 <= main.frame.minY)
        #expect(main.frame.maxY + 10 <= title.frame.minY)
        panel.close()
    }

    @Test("Interactive popup text resolves dark in Aqua and light in Dark Aqua")
    func interactiveColorsFollowAppearance() throws {
        for (appearanceName, expectsLightForeground) in [
            (NSAppearance.Name.aqua, false),
            (.darkAqua, true),
        ] {
            let panel = makePanel()
            panel.showInteractive(text: "Draft", title: "Edit", onConfirm: { _ in })
            panel.showPendingAppend("Pending body", title: "Pending title")

            let window = try #require(editorWindow(containing: "Draft"))
            let appearance = try #require(NSAppearance(named: appearanceName))
            window.appearance = appearance
            let views = descendants(of: window.contentView)
            let title = try #require(views.compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "preview.status"
            })
            let editor = try #require(views.compactMap { $0 as? DictionaryAwareTextView }.first)
            let pending = try #require(views.compactMap { $0 as? NSTextView }.first {
                !($0 is DictionaryAwareTextView) && $0.string.contains("Pending body")
            })

            let pendingTitleIndex = 0
            let pendingBodyIndex = ("Pending title\n" as NSString).length
            let colors = [
                try #require(title.textColor),
                try foregroundColor(in: editor, at: 0),
                try #require(editor.insertionPointColor),
                try foregroundColor(in: pending, at: pendingTitleIndex),
                try foregroundColor(in: pending, at: pendingBodyIndex),
            ]
            for color in colors {
                let luminance = try resolvedLuminance(color, appearance: appearance)
                if expectsLightForeground {
                    #expect(luminance > 0.6)
                } else {
                    #expect(luminance < 0.4)
                }
            }
            panel.close()
        }
    }

    @Test("Recording HUD text resolves dark in Aqua and light in Dark Aqua")
    func hudColorsFollowAppearance() throws {
        for (appearanceName, expectsLightForeground) in [
            (NSAppearance.Name.aqua, false),
            (.darkAqua, true),
        ] {
            let panel = makePanel()
            panel.show(title: "Recording")
            panel.updateText("Live text")

            let window = try #require(NSApp.windows.first { window in
                window.isVisible && descendants(of: window.contentView).contains { view in
                    (view as? NSTextField)?.accessibilityIdentifier() == "preview.live-text"
                }
            })
            let appearance = try #require(NSAppearance(named: appearanceName))
            window.appearance = appearance
            let fields = descendants(of: window.contentView).compactMap { $0 as? NSTextField }
            let title = try #require(fields.first { $0.accessibilityIdentifier() == "preview.status" })
            let live = try #require(fields.first { $0.accessibilityIdentifier() == "preview.live-text" })

            for color in [try #require(title.textColor), try #require(live.textColor)] {
                let luminance = try resolvedLuminance(color, appearance: appearance)
                if expectsLightForeground {
                    #expect(luminance > 0.6)
                } else {
                    #expect(luminance < 0.4)
                }
            }
            panel.close()
        }
    }

    private func editorWindow(containing marker: String) -> NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible,
                  let scroll = window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let editor = scroll.documentView as? DictionaryAwareTextView else {
                return false
            }
            return editor.string.contains(marker)
        }
    }

    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func foregroundColor(in textView: NSTextView, at index: Int) throws -> NSColor {
        let value = textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil)
        return try #require(value as? NSColor)
    }

    private func resolvedLuminance(_ color: NSColor, appearance: NSAppearance) throws -> CGFloat {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB)
        }
        let rgb = try #require(resolved)
        return 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
    }

    @Test("Interactive editor exposes a stable VoiceOver identifier")
    func editorAccessibility() {
        let panel = makePanel()
        panel.showInteractive(text: "sanitized fixture", title: "Edit", onConfirm: { _ in })
        #expect(panel.editorAccessibilityIdentifierForTesting == "preview.editor")
        panel.close()
    }

    @Test("HUD is ordered out after its fade rather than remaining invisible")
    func fadeOrdersOut() async {
        let panel = makePanel()
        panel.show(title: "Recording")
        #expect(panel.isVisibleForTesting)
        panel.hide(delay: 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while panel.isVisibleForTesting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(!panel.isVisibleForTesting)
        panel.close()
    }
}
