import AppKit
import CNSCore
import Foundation

/// Restores focus to the app the user dictated from, then injects the text.
///
/// Ported from `_activate_previous_app_and_inject` + `_start_injection_worker`.
/// When focus cannot be restored the text goes to the clipboard and the user is
/// told to paste it — it is never injected blind into whatever is in front.
@MainActor
public struct SystemTextDelivery: TextDelivering {
    private let restorer: FocusRestorer
    private let injector: TextInjector
    private let copyToClipboard: @Sendable (String) -> Void
    private let notify: @Sendable (String, String, String) -> Void
    private let log: @Sendable (String) -> Void

    public init(
        restorer: FocusRestorer? = nil,
        injector: TextInjector? = nil,
        copyToClipboard: (@Sendable (String) -> Void)? = nil,
        notify: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.restorer = restorer ?? FocusRestorer(log: log)
        self.injector = injector ?? TextInjector(log: log, notify: notify)
        self.copyToClipboard = copyToClipboard ?? { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        self.notify = notify
        self.log = log
    }

    public func deliver(_ text: String, to pid: pid_t?) async -> Bool {
        switch await restorer.restore(to: pid) {
        case .confirmed:
            let result = await injector.inject(text)
            if !result.success {
                log("Injection failed: method=\(result.method) error=\(result.error ?? "-")")
            }
            return result.success

        case .targetUnavailable:
            log("Target app unavailable; text copied to clipboard instead.")
            copyToClipboard(text)
            notify("Click-n-speak", "Text copied", "Could not restore the target app. Paste the text manually.")
            return false

        case .timedOut:
            log("Focus restore timed out; text copied to clipboard instead.")
            copyToClipboard(text)
            notify("Click-n-speak", "Text copied", "The target app did not regain focus. Paste the text manually.")
            return false
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
