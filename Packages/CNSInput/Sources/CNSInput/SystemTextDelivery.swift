import AppKit
import CNSCore
import Foundation

/// Restores focus to the app the user dictated from, then injects the text.
///
/// Ported from `_activate_previous_app_and_inject` + `_start_injection_worker`.
/// When focus cannot be restored the text goes to the clipboard and the user is
/// told to paste it — it is never injected blind into whatever is in front.
public struct TextDeliveryStrings: Sendable, Equatable {
    public var appTitle: String
    public var textCopiedTitle: String
    public var targetUnavailableBody: String
    public var focusTimedOutBody: String
    public var injection: TextInjectionStrings

    public init(
        appTitle: String = "Click-n-speak",
        textCopiedTitle: String = "Text copied",
        targetUnavailableBody: String = "Could not restore the target app. Paste the text manually.",
        focusTimedOutBody: String = "The target app did not regain focus. Paste the text manually.",
        injection: TextInjectionStrings = TextInjectionStrings()
    ) {
        self.appTitle = appTitle
        self.textCopiedTitle = textCopiedTitle
        self.targetUnavailableBody = targetUnavailableBody
        self.focusTimedOutBody = focusTimedOutBody
        self.injection = injection
    }
}

@MainActor
public struct SystemTextDelivery: TextDelivering {
    private let restorer: FocusRestorer
    private let injector: TextInjector
    private let copyToClipboard: @Sendable (String) -> Void
    private let notify: @Sendable (String, String, String) -> Void
    private let log: @Sendable (String) -> Void
    private let strings: TextDeliveryStrings

    public init(
        restorer: FocusRestorer? = nil,
        injector: TextInjector? = nil,
        copyToClipboard: (@Sendable (String) -> Void)? = nil,
        notify: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in },
        log: @escaping @Sendable (String) -> Void = { _ in },
        strings: TextDeliveryStrings = TextDeliveryStrings()
    ) {
        self.restorer = restorer ?? FocusRestorer(log: log)
        self.injector = injector ?? TextInjector(strings: strings.injection, log: log, notify: notify)
        self.copyToClipboard = copyToClipboard ?? { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        self.notify = notify
        self.log = log
        self.strings = strings
    }

    public func deliver(_ text: String, to pid: pid_t?) async -> TextDeliveryOutcome {
        switch await restorer.restore(to: pid) {
        case .confirmed:
            guard !Task.isCancelled else { return .cancelled }
            let result = await injector.inject(text)
            if !result.success {
                log("Injection failed: method=\(result.method) error=\(result.error ?? "-")")
            }
            switch result.failure {
            case nil where result.success:
                return .delivered
            case .accessibilityDenied:
                return .failed(.accessibilityDenied)
            case .cancelled:
                return .cancelled
            default:
                return .failed(.injectionFailed)
            }

        case .targetUnavailable:
            log("Target app unavailable; text copied to clipboard instead.")
            copyToClipboard(text)
            notify(strings.appTitle, strings.textCopiedTitle, strings.targetUnavailableBody)
            return .failed(.targetUnavailable)

        case .timedOut:
            log("Focus restore timed out; text copied to clipboard instead.")
            copyToClipboard(text)
            notify(strings.appTitle, strings.textCopiedTitle, strings.focusTimedOutBody)
            return .failed(.focusTimedOut)

        case .cancelled:
            log("Focus restore cancelled before injection.")
            return .cancelled
        }
    }
}

/// The real frontmost-app source.
@MainActor
public struct WorkspaceFrontmostProvider: FrontmostAppProviding {
    public init() {}

    public func frontmostPid() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
