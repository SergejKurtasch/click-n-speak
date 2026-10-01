import Foundation
import Testing
@testable import CNSInput

/// Records what the injector did to the pasteboard and lets a test force failures.
private final class MockClipboard: ClipboardAdapting, @unchecked Sendable {
    // @unchecked Sendable: the injector touches this from one task at a time; the
    // lock is only here so a test can read the log afterwards without a race.
    struct Behaviour {
        var available = true
        var snapshotError: Error?
        var setTextError: Error?
        var restoreError: Error?
        /// What `changeCount` reports at restore time; nil = unchanged.
        var changeCountAtRestore: Int?
    }

    private let lock = NSLock()
    private var behaviour: Behaviour
    private(set) var writtenText: String?
    private(set) var restoreAttempts = 0
    private(set) var restoresPerformed = 0
    private let stored = PasteboardSnapshot(items: [[PasteboardEntry(type: "public.utf8-plain-text", data: Data("old".utf8))]])

    init(_ behaviour: Behaviour = Behaviour()) { self.behaviour = behaviour }

    func isAvailable() -> Bool { behaviour.available }

    func snapshot() throws -> PasteboardSnapshot {
        if let error = behaviour.snapshotError { throw error }
        return stored
    }

    func setText(_ text: String) throws -> Int {
        if let error = behaviour.setTextError { throw error }
        lock.lock(); writtenText = text; lock.unlock()
        return 42
    }

    @discardableResult
    func restoreIfUnchanged(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) throws -> Bool {
        lock.lock(); restoreAttempts += 1; lock.unlock()
        if let error = behaviour.restoreError { throw error }
        let actual = behaviour.changeCountAtRestore ?? expectedChangeCount
        guard actual == expectedChangeCount else { return false }
        lock.lock(); restoresPerformed += 1; lock.unlock()
        #expect(snapshot == stored)
        return true
    }
}

private final class MockKeyboard: KeyboardAdapting, @unchecked Sendable {
    // @unchecked Sendable: written once by the injector, read after it returns.
    var pasteError: Error?
    var typeError: Error?
    private(set) var pasteCount = 0
    private(set) var typedText: String?

    func paste() throws {
        if let pasteError { throw pasteError }
        pasteCount += 1
    }

    func typeText(_ text: String) throws {
        if let typeError { throw typeError }
        typedText = text
    }
}

private struct Boom: Error, Equatable {}

@Suite("TextInjector")
struct TextInjectorTests {
    private func injector(
        clipboard: any ClipboardAdapting,
        keyboard: any KeyboardAdapting,
        trusted: Bool = true,
        notify: (@Sendable (String, String, String) -> Void)? = nil
    ) -> TextInjector {
        TextInjector(
            clipboard: clipboard,
            keyboard: keyboard,
            isAccessibilityTrusted: { trusted },
            restoreDelay: 0,
            notify: notify ?? { _, _, _ in }
        )
    }

    @Test("Empty text is a no-op success")
    func emptyText() async {
        let clipboard = MockClipboard()
        let keyboard = MockKeyboard()
        let result = await injector(clipboard: clipboard, keyboard: keyboard).inject("")

        #expect(result == InjectionResult(success: true, method: .none, charCount: 0, duration: 0))
        #expect(keyboard.pasteCount == 0)
        #expect(clipboard.writtenText == nil)
    }

    @Test("Cancellation during pre-delay performs no injection side effect")
    func cancelledBeforeInjection() async {
        let clipboard = MockClipboard()
        let keyboard = MockKeyboard()
        let subject = injector(clipboard: clipboard, keyboard: keyboard)
        let task = Task { await subject.inject("keep", preDelay: 10) }
        await Task.yield()
        task.cancel()

        let result = await task.value

        #expect(result.failure == .cancelled)
        #expect(clipboard.writtenText == nil)
        #expect(keyboard.pasteCount == 0)
        #expect(keyboard.typedText == nil)
    }

    @Test("Without Accessibility nothing is pasted and the user is notified")
    func noAccessibility() async {
        let clipboard = MockClipboard()
        let keyboard = MockKeyboard()
        let notified = NotificationRecorder()

        let result = await injector(
            clipboard: clipboard,
            keyboard: keyboard,
            trusted: false,
            notify: { title, subtitle, body in notified.record(title, subtitle, body) }
        ).inject("привет")

        #expect(result.success == false)
        #expect(result.method == .none)
        #expect(result.charCount == 6)
        #expect(keyboard.pasteCount == 0)
        #expect(clipboard.writtenText == nil)
        #expect(notified.count == 1)
    }

    @Test("Happy path: text written, ⌘V sent, clipboard restored")
    func pasteAndRestore() async {
        let clipboard = MockClipboard()
        let keyboard = MockKeyboard()

        let result = await injector(clipboard: clipboard, keyboard: keyboard).inject("hello world")

        #expect(result.success == true)
        #expect(result.method == .paste)
        #expect(result.charCount == 11)
        #expect(clipboard.writtenText == "hello world")
        #expect(keyboard.pasteCount == 1)
        #expect(clipboard.restoresPerformed == 1)
    }

    @Test("A clipboard the user changed during the delay is never overwritten")
    func doesNotRestoreOverUserCopy() async {
        var behaviour = MockClipboard.Behaviour()
        behaviour.changeCountAtRestore = 99  // someone else copied after us
        let clipboard = MockClipboard(behaviour)
        let keyboard = MockKeyboard()

        let result = await injector(clipboard: clipboard, keyboard: keyboard).inject("hello")

        #expect(result.success == true)
        #expect(result.method == .paste)
        #expect(clipboard.restoreAttempts == 1)
        #expect(clipboard.restoresPerformed == 0)  // skipped — user content wins
    }

    @Test("An unavailable pasteboard falls back to typing")
    func fallbackWhenUnavailable() async {
        var behaviour = MockClipboard.Behaviour()
        behaviour.available = false
        let clipboard = MockClipboard(behaviour)
        let keyboard = MockKeyboard()

        let result = await injector(clipboard: clipboard, keyboard: keyboard).inject("текст")

        #expect(result.method == .typing)
        #expect(result.success == true)
        #expect(keyboard.typedText == "текст")
        #expect(keyboard.pasteCount == 0)
    }

    @Test("A pasteboard write failure types instead, with nothing to restore")
    func fallbackWhenWriteFails() async {
        var behaviour = MockClipboard.Behaviour()
        behaviour.setTextError = Boom()
        let clipboard = MockClipboard(behaviour)
        let keyboard = MockKeyboard()

        let result = await injector(clipboard: clipboard, keyboard: keyboard).inject("text")

        #expect(result.method == .typing)
        #expect(result.success == true)
        // Our text never reached the pasteboard, so restoring would be pointless.
        #expect(clipboard.restoreAttempts == 0)
        #expect(keyboard.typedText == "text")
    }

    @Test("A failed ⌘V restores the clipboard, then types the text")
    func fallbackWhenPasteFails() async {
        let clipboard = MockClipboard()
        let keyboard = MockKeyboard()
        keyboard.pasteError = Boom()

        let result = await injector(clipboard: clipboard, keyboard: keyboard).inject("text")

        #expect(result.method == .typing)
        #expect(keyboard.typedText == "text")
        // Our text is sitting on the pasteboard and must be taken back off it.
        #expect(clipboard.restoresPerformed == 1)
    }

    @Test("A restore failure after a successful paste still counts as success")
    func restoreFailureAfterPaste() async {
        var behaviour = MockClipboard.Behaviour()
        behaviour.restoreError = Boom()
        let clipboard = MockClipboard(behaviour)
        let keyboard = MockKeyboard()

        let result = await injector(clipboard: clipboard, keyboard: keyboard).inject("text")

        #expect(result.success == true)
        #expect(result.method == .paste)
        #expect(result.error != nil)
        #expect(keyboard.typedText == nil)  // not typed twice
    }

    @Test("When both paths fail the result is a failure and the user is notified")
    func bothPathsFail() async {
        var behaviour = MockClipboard.Behaviour()
        behaviour.available = false
        let clipboard = MockClipboard(behaviour)
        let keyboard = MockKeyboard()
        keyboard.typeError = Boom()
        let notified = NotificationRecorder()

        let result = await injector(
            clipboard: clipboard,
            keyboard: keyboard,
            notify: { title, subtitle, body in notified.record(title, subtitle, body) }
        ).inject("text")

        #expect(result.success == false)
        #expect(result.method == .typing)
        #expect(notified.count == 1)
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, String, String)] = []

    func record(_ title: String, _ subtitle: String, _ body: String) {
        lock.lock(); entries.append((title, subtitle, body)); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
