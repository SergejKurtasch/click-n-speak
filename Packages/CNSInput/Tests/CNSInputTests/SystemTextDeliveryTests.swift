import CNSCore
import Foundation
import Testing
@testable import CNSInput

@MainActor
@Suite("System text delivery")
struct SystemTextDeliveryTests {
    @Test("A missing target copies text, notifies, and remains a failed delivery")
    func missingTargetPreservesText() async {
        let copied = StringRecorder()
        let notified = DeliveryNotificationRecorder()
        let delivery = SystemTextDelivery(
            restorer: FocusRestorer(activate: { _ in false }, frontmostPid: { nil }),
            copyToClipboard: { copied.record($0) },
            notify: { notified.record(title: $0, subtitle: $1, body: $2) },
            strings: .testing
        )

        let outcome = await delivery.deliver("keep me", to: 42)

        #expect(outcome == .failed(.targetUnavailable))
        #expect(copied.values == ["keep me"])
        #expect(notified.entries == [.init(title: "app", subtitle: "copied", body: "target missing")])
    }

    @Test("Missing Accessibility notifies but never reports insertion success")
    func missingAccessibilityIsFailure() async {
        let notified = DeliveryNotificationRecorder()
        let injector = TextInjector(
            isAccessibilityTrusted: { false },
            restoreDelay: 0,
            strings: .testing,
            notify: { notified.record(title: $0, subtitle: $1, body: $2) }
        )
        let delivery = SystemTextDelivery(
            restorer: FocusRestorer(
                requiredStableChecks: 1,
                activate: { _ in true },
                frontmostPid: { 42 }
            ),
            injector: injector,
            notify: { notified.record(title: $0, subtitle: $1, body: $2) },
            strings: .testing
        )

        let outcome = await delivery.deliver("keep me", to: 42)

        #expect(outcome == .failed(.accessibilityDenied))
        #expect(notified.entries == [.init(title: "app", subtitle: "permissions", body: "allow accessibility")])
    }

    @Test("A focus timeout copies text and uses the distinct localized message")
    func focusTimeoutPreservesText() async {
        let copied = StringRecorder()
        let notified = DeliveryNotificationRecorder()
        let delivery = SystemTextDelivery(
            restorer: FocusRestorer(
                timeout: 0,
                requiredStableChecks: 2,
                activate: { _ in true },
                frontmostPid: { 7 }
            ),
            copyToClipboard: { copied.record($0) },
            notify: { notified.record(title: $0, subtitle: $1, body: $2) },
            strings: .testing
        )

        let outcome = await delivery.deliver("keep me", to: 42)

        #expect(outcome == .failed(.focusTimedOut))
        #expect(copied.values == ["keep me"])
        #expect(notified.entries == [.init(title: "app", subtitle: "copied", body: "focus timeout")])
    }

    @Test("Cancelling a focus wait finishes without a clipboard or notification fallback")
    func cancelledFocusWaitStops() async {
        let copied = StringRecorder()
        let notified = DeliveryNotificationRecorder()
        let delivery = SystemTextDelivery(
            restorer: FocusRestorer(
                timeout: 10,
                poll: 0.01,
                activate: { _ in true },
                frontmostPid: { 7 }
            ),
            copyToClipboard: { copied.record($0) },
            notify: { notified.record(title: $0, subtitle: $1, body: $2) },
            strings: .testing
        )
        let task = Task { await delivery.deliver("keep me", to: 42) }
        await Task.yield()
        task.cancel()

        let outcome = await task.value

        #expect(outcome == .cancelled)
        #expect(copied.values.isEmpty)
        #expect(notified.entries.isEmpty)
    }
}

private extension TextDeliveryStrings {
    static let testing = TextDeliveryStrings(
        appTitle: "app",
        textCopiedTitle: "copied",
        targetUnavailableBody: "target missing",
        focusTimedOutBody: "focus timeout",
        injection: .testing
    )
}

private extension TextInjectionStrings {
    static let testing = TextInjectionStrings(
        appTitle: "app",
        accessibilityTitle: "permissions",
        accessibilityBody: "allow accessibility",
        failureTitle: "failed",
        failureBody: "copy manually"
    )
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    var values: [String] {
        lock.withLock { storage }
    }
}

private final class DeliveryNotificationRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let title: String
        let subtitle: String
        let body: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func record(title: String, subtitle: String, body: String) {
        lock.withLock { storage.append(.init(title: title, subtitle: subtitle, body: body)) }
    }

    var entries: [Entry] {
        lock.withLock { storage }
    }
}
