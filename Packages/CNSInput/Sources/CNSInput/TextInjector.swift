import Foundation

/// Outcome of one injection attempt. Mirrors `InjectionResult` in `injector.py`.
public struct InjectionResult: Sendable, Equatable {
    public enum Method: String, Sendable {
        case none
        case paste
        case typing
    }

    public let success: Bool
    public let method: Method
    public let charCount: Int
    public let duration: TimeInterval
    public let error: String?
    public let failure: InjectionFailure?

    public init(
        success: Bool,
        method: Method,
        charCount: Int,
        duration: TimeInterval,
        error: String? = nil,
        failure: InjectionFailure? = nil
    ) {
        self.success = success
        self.method = method
        self.charCount = charCount
        self.duration = duration
        self.error = error
        self.failure = failure
    }
}

public enum InjectionFailure: String, Sendable, Equatable {
    case accessibilityDenied
    case keyboardUnavailable
    case cancelled
}

public enum InjectionError: Error, Equatable {
    case pasteboardUnavailable
    case pasteboardRejectedText
    case keyboardEventsUnavailable
}

public struct TextInjectionStrings: Sendable, Equatable {
    public var appTitle: String
    public var accessibilityTitle: String
    public var accessibilityBody: String
    public var failureTitle: String
    public var failureBody: String

    public init(
        appTitle: String = "Click-n-speak",
        accessibilityTitle: String = "Permissions Required",
        accessibilityBody: String = "Allow Click-n-speak in System Settings → Privacy & Security → Accessibility.",
        failureTitle: String = "Injection Failed",
        failureBody: String = "Could not insert text. Check Accessibility permissions."
    ) {
        self.appTitle = appTitle
        self.accessibilityTitle = accessibilityTitle
        self.accessibilityBody = accessibilityBody
        self.failureTitle = failureTitle
        self.failureBody = failureBody
    }
}

/// Pastes text into the frontmost app, preserving the user's clipboard.
///
/// Ported from `inject_text` in `injector.py`, including its fallback order:
/// clipboard + ⌘V first, throttled Unicode typing only if the pasteboard path
/// fails. The clipboard is restored **only** when its `changeCount` still matches
/// what we wrote — anything else means the user copied something during the
/// restore delay and their content wins (§6 invariant 3).
public struct TextInjector: Sendable {
    private let clipboard: any ClipboardAdapting
    private let keyboard: any KeyboardAdapting
    private let isAccessibilityTrusted: @Sendable () -> Bool
    private let restoreDelay: TimeInterval
    private let strings: TextInjectionStrings
    private let log: @Sendable (String) -> Void
    /// (title, subtitle, body) — same shape as `send_notification`.
    private let notify: @Sendable (String, String, String) -> Void

    public init(
        clipboard: any ClipboardAdapting = MacPasteboardAdapter(),
        keyboard: any KeyboardAdapting = QuartzKeyboardAdapter(),
        isAccessibilityTrusted: @escaping @Sendable () -> Bool = { AccessibilityTrust.isTrusted() },
        restoreDelay: TimeInterval = 0.35,
        strings: TextInjectionStrings = TextInjectionStrings(),
        log: @escaping @Sendable (String) -> Void = { _ in },
        notify: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in }
    ) {
        self.clipboard = clipboard
        self.keyboard = keyboard
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.restoreDelay = restoreDelay
        self.strings = strings
        self.log = log
        self.notify = notify
    }

    /// Insert `text` into whatever app is frontmost. Never call this before the
    /// focus checks in `FocusRestorer` have passed.
    public func inject(_ text: String, preDelay: TimeInterval = 0) async -> InjectionResult {
        let startedAt = Date()
        func elapsed() -> TimeInterval { Date().timeIntervalSince(startedAt) }

        guard !Task.isCancelled else {
            return InjectionResult(
                success: false,
                method: .none,
                charCount: text.count,
                duration: elapsed(),
                error: "Injection cancelled",
                failure: .cancelled
            )
        }
        if text.isEmpty {
            return InjectionResult(success: true, method: .none, charCount: 0, duration: 0)
        }

        guard isAccessibilityTrusted() else {
            let error = "Accessibility permissions are not granted"
            log("\(error). Cannot inject text.")
            notify(
                strings.appTitle,
                strings.accessibilityTitle,
                strings.accessibilityBody
            )
            return InjectionResult(
                success: false,
                method: .none,
                charCount: text.count,
                duration: elapsed(),
                error: error,
                failure: .accessibilityDenied
            )
        }

        if preDelay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
            } catch {
                return InjectionResult(
                    success: false,
                    method: .none,
                    charCount: text.count,
                    duration: elapsed(),
                    error: "Injection cancelled",
                    failure: .cancelled
                )
            }
        }

        if clipboard.isAvailable() {
            var pasteSent = false
            var snapshot: PasteboardSnapshot?
            var changeCount: Int?
            do {
                let taken = try clipboard.snapshot()
                snapshot = taken
                let written = try clipboard.setText(text)
                changeCount = written
                log("Attempting atomic text injection: chars=\(text.count)")
                try keyboard.paste()
                pasteSent = true
                if restoreDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
                }
                _ = try clipboard.restoreIfUnchanged(taken, expectedChangeCount: written)
                let duration = elapsed()
                log("Text injection successful: method=paste chars=\(text.count) duration=\(fmt(duration))s")
                return InjectionResult(success: true, method: .paste, charCount: text.count, duration: duration)
            } catch {
                if pasteSent {
                    // The text is already in the target app; only the restore failed.
                    log("Paste was sent but clipboard restoration failed: \(error)")
                    return InjectionResult(
                        success: true,
                        method: .paste,
                        charCount: text.count,
                        duration: elapsed(),
                        error: "\(error)"
                    )
                }
                if let snapshot, let changeCount {
                    do {
                        _ = try clipboard.restoreIfUnchanged(snapshot, expectedChangeCount: changeCount)
                    } catch {
                        log("Failed to restore clipboard before typing fallback: \(error)")
                    }
                }
                log("Atomic paste unavailable, falling back to typing: \(error)")
            }
        }

        guard !Task.isCancelled else {
            return InjectionResult(
                success: false,
                method: .none,
                charCount: text.count,
                duration: elapsed(),
                error: "Injection cancelled",
                failure: .cancelled
            )
        }
        do {
            log("Attempting typed text injection: chars=\(text.count)")
            try keyboard.typeText(text)
            let duration = elapsed()
            log("Text injection successful: method=typing chars=\(text.count) duration=\(fmt(duration))s")
            return InjectionResult(success: true, method: .typing, charCount: text.count, duration: duration)
        } catch {
            log("Text injection failed: \(error)")
            notify(strings.appTitle, strings.failureTitle, strings.failureBody)
            return InjectionResult(
                success: false,
                method: .typing,
                charCount: text.count,
                duration: elapsed(),
                error: "\(error)",
                failure: .keyboardUnavailable
            )
        }
    }

    private func fmt(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }
}
