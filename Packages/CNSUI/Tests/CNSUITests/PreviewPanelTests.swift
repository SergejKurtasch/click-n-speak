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
        #expect(panel.currentText == nil)  // HUD mode has no editor

        panel.showInteractive(text: "итог", title: "Edit", onConfirm: { _ in })
        #expect(panel.currentText == "итог")

        _ = panel.handleKey(keyCode: keyEscape, hasCommand: false, characters: nil)
        // Back to the HUD layout without a stale editor.
        panel.show(title: "Ready")
        #expect(panel.currentText == nil)
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
}
