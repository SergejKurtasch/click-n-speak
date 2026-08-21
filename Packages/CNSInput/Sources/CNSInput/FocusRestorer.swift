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
    private let log: @Sendable (String) -> Void

    public init(
        timeout: TimeInterval = FocusRestorer.timeoutSeconds,
        poll: TimeInterval = FocusRestorer.pollSeconds,
        requiredStableChecks: Int = FocusRestorer.stableChecks,
        activate: @escaping @MainActor (pid_t) -> Bool = FocusRestorer.activateRunningApp,
        frontmostPid: @escaping @MainActor () -> pid_t? = FocusRestorer.workspaceFrontmostPid,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.timeout = timeout
        self.poll = poll
        self.requiredStableChecks = requiredStableChecks
        self.activate = activate
        self.frontmostPid = frontmostPid
        self.log = log
    }

    public func restore(to targetPid: pid_t?) async -> FocusOutcome {
        guard let targetPid, targetPid > 0 else {
            log("Cannot restore target app focus: no captured pid.")
            return .targetUnavailable
        }
        guard activate(targetPid) else {
            log("Target app pid=\(targetPid) is no longer running.")
            return .targetUnavailable
        }

        log("Focus activation requested: target_pid=\(targetPid)")
        let deadline = Date().addingTimeInterval(timeout)
        var stable = 0

        while true {
            let current = frontmostPid()
            stable = (current == targetPid) ? stable + 1 : 0

            if stable >= requiredStableChecks {
                log("Focus confirmed: target_pid=\(targetPid)")
                return .confirmed
            }
            if Date() >= deadline {
                log("Focus restore timed out: target_pid=\(targetPid) frontmost_pid=\(current.map(String.init) ?? "nil")")
                return .timedOut(frontmostPid: current)
            }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
    }

    // MARK: - Real implementations

    public static func activateRunningApp(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        app.activate(options: [])
        return true
    }

    public static func workspaceFrontmostPid() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
