import ApplicationServices
import AppKit
import Foundation

/// Result of trying to hand focus back to the app the user dictated into.
public enum FocusOutcome: Equatable, Sendable {
    /// The target app has been frontmost for two consecutive checks — safe to inject.
    case confirmed
    /// No target pid was captured, or that process is gone.
    case targetUnavailable
    /// The target never came back within the deadline; `frontmostPid` is what was
    /// in front when we gave up.
    case timedOut(frontmostPid: pid_t?)
    /// The owner is terminating; no fallback should mutate the clipboard.
    case cancelled
}

/// Diagnostic snapshot of application and Accessibility focus state.
public struct FocusDiagnostics: Equatable, Sendable {
    public let frontmostPid: pid_t?
    public let targetIsActive: Bool
    public let selfIsActive: Bool
    public let axFocusedWindowPresent: Bool
    public let axFocusedElementRole: String?
    public let axError: Int32

    public init(
        frontmostPid: pid_t?,
        targetIsActive: Bool,
        selfIsActive: Bool,
        axFocusedWindowPresent: Bool,
        axFocusedElementRole: String?,
        axError: Int32 = 0
    ) {
        self.frontmostPid = frontmostPid
        self.targetIsActive = targetIsActive
        self.selfIsActive = selfIsActive
        self.axFocusedWindowPresent = axFocusedWindowPresent
        self.axFocusedElementRole = axFocusedElementRole
        self.axError = axError
    }

    var logSummary: String {
        let front = frontmostPid.map(String.init) ?? "nil"
        let role = axFocusedElementRole ?? "nil"
        return "frontmost_pid=\(front) target_active=\(targetIsActive) self_active=\(selfIsActive) ax_window=\(axFocusedWindowPresent) ax_role=\(role) ax_err=\(axError)"
    }
}

/// Waits for the previously focused app to actually be frontmost again before any
/// text is injected.
///
/// Ported from `_activate_previous_app_and_inject` in `app.py`. The wait matters:
/// activation is asynchronous, and pasting one frame too early puts the user's
/// dictation into whatever window happens to be in front — often our own popup.
/// Hence two *consecutive* confirmations (§6 invariant 2), polled on the main
/// thread, before the caller may inject.
@MainActor
public struct FocusRestorer {
    public static let timeoutSeconds: TimeInterval = 1.5
    public static let pollSeconds: TimeInterval = 0.05
    public static let stableChecks = 2

    private let timeout: TimeInterval
    private let poll: TimeInterval
    private let requiredStableChecks: Int
    /// Brings the app with this pid forward; false when it is no longer running.
    private let activate: @MainActor (pid_t) -> Bool
    private let frontmostPid: @MainActor () -> pid_t?
    private let isTargetReady: @MainActor (pid_t) -> Bool
    private let diagnosticsProvider: @MainActor (pid_t, pid_t?) -> FocusDiagnostics
    private let log: @Sendable (String) -> Void

    public init(
        timeout: TimeInterval = FocusRestorer.timeoutSeconds,
        poll: TimeInterval = FocusRestorer.pollSeconds,
        requiredStableChecks: Int = FocusRestorer.stableChecks,
        activate: @escaping @MainActor (pid_t) -> Bool = FocusRestorer.activateRunningApp,
        frontmostPid: @escaping @MainActor () -> pid_t? = FocusRestorer.workspaceFrontmostPid,
        isTargetReady: @escaping @MainActor (pid_t) -> Bool = FocusRestorer.isRunningAppReadyForInput,
        diagnosticsProvider: @escaping @MainActor (pid_t, pid_t?) -> FocusDiagnostics = FocusRestorer.captureDiagnostics,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.timeout = timeout
        self.poll = poll
        self.requiredStableChecks = requiredStableChecks
        self.activate = activate
        self.frontmostPid = frontmostPid
        self.isTargetReady = isTargetReady
        self.diagnosticsProvider = diagnosticsProvider
        self.log = log
    }

    public func restore(to targetPid: pid_t?) async -> FocusOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let targetPid, targetPid > 0 else {
            log("Cannot restore target app focus: no captured pid.")
            return .targetUnavailable
        }
        guard activate(targetPid) else {
            log("Target app pid=\(targetPid) is no longer running.")
            return .targetUnavailable
        }

        let initialDiag = diagnosticsProvider(targetPid, nil)
        log("Focus activation requested: target_pid=\(targetPid) \(initialDiag.logSummary)")
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timeout)
        var stable = 0
        var polls = 0

        while true {
            guard !Task.isCancelled else { return .cancelled }
            let current = frontmostPid()
            let ready = (current == targetPid) && isTargetReady(targetPid)
            stable = ready ? stable + 1 : 0
            polls += 1

            if stable >= requiredStableChecks {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let finalDiag = diagnosticsProvider(targetPid, current)
                log("Focus confirmed: target_pid=\(targetPid) polls=\(polls) elapsed_ms=\(elapsedMs) \(finalDiag.logSummary)")
                return .confirmed
            }
            if Date() >= deadline {
                let finalDiag = diagnosticsProvider(targetPid, current)
                log("Focus restore timed out: target_pid=\(targetPid) polls=\(polls) \(finalDiag.logSummary)")
                return .timedOut(frontmostPid: current)
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
            } catch {
                return .cancelled
            }
        }
    }

    // MARK: - Real implementations

    public static func activateRunningApp(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }
        if #available(macOS 14.0, *) {
            NSApp?.yieldActivation(to: app)
            NSApp?.deactivate()
            _ = app.activate()
        } else {
            NSApp?.deactivate()
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
        return true
    }

    public static func workspaceFrontmostPid() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public static func isRunningAppReadyForInput(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else {
            // In unit tests with synthetic PIDs or non-regular processes, fall back to frontmostPid matching.
            return true
        }
        return app.isActive
    }

    public static func captureDiagnostics(targetPid: pid_t, frontmostPid: pid_t?) -> FocusDiagnostics {
        let resolvedFrontmost = frontmostPid ?? workspaceFrontmostPid()
        let targetApp = NSRunningApplication(processIdentifier: targetPid)
        let targetActive = targetApp?.isActive ?? false
        let selfActive = NSApp?.isActive ?? false

        let appElement = AXUIElementCreateApplication(targetPid)
        var focusedWindow: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        var focusedElement: CFTypeRef?
        let elemErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        var roleString: String?
        if elemErr == .success, let focusedElement {
            var roleValue: CFTypeRef?
            let axElem = unsafeDowncast(focusedElement as AnyObject, to: AXUIElement.self)
            if AXUIElementCopyAttributeValue(axElem, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String {
                roleString = role
            }
        }
        let primaryErr = elemErr != .success ? elemErr.rawValue : winErr.rawValue
        return FocusDiagnostics(
            frontmostPid: resolvedFrontmost,
            targetIsActive: targetActive,
            selfIsActive: selfActive,
            axFocusedWindowPresent: winErr == .success && focusedWindow != nil,
            axFocusedElementRole: roleString,
            axError: primaryErr
        )
    }
}
