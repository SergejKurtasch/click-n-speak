import Foundation
import Testing
@testable import CNSInput

@MainActor
@Suite("FocusRestorer")
struct FocusRestorerTests {
    /// Replays a scripted sequence of frontmost pids, one per poll.
    private final class Frontmost {
        private var sequence: [pid_t?]
        private(set) var reads = 0
        private let last: pid_t?

        init(_ sequence: [pid_t?]) {
            self.sequence = sequence
            self.last = sequence.last ?? nil
        }

        func next() -> pid_t? {
            reads += 1
            return sequence.isEmpty ? last : sequence.removeFirst()
        }
    }

    private func restorer(
        _ frontmost: Frontmost,
        activates: Bool = true,
        timeout: TimeInterval = 0.5,
        isTargetReady: @escaping @MainActor (pid_t) -> Bool = { _ in true },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> FocusRestorer {
        FocusRestorer(
            timeout: timeout,
            poll: 0.005,
            activate: { _ in activates },
            frontmostPid: { frontmost.next() },
            isTargetReady: isTargetReady,
            diagnosticsProvider: { targetPid, currentPid in
                FocusDiagnostics(
                    frontmostPid: currentPid,
                    targetIsActive: currentPid == targetPid,
                    selfIsActive: false,
                    axFocusedWindowPresent: true,
                    axFocusedElementRole: "AXTextArea",
                    axError: 0
                )
            },
            log: log
        )
    }

    @Test("Two consecutive matches confirm focus")
    func confirmsAfterTwoStableChecks() async {
        let frontmost = Frontmost([501, 501])
        let outcome = await restorer(frontmost).restore(to: 501)

        #expect(outcome == .confirmed)
        #expect(frontmost.reads == 2)
    }

    @Test("A single match is not enough — the counter resets on a mismatch")
    func resetsOnMismatch() async {
        // Frontmost flickers back to another app between two matches.
        let frontmost = Frontmost([501, 999, 501, 501])
        let outcome = await restorer(frontmost).restore(to: 501)

        #expect(outcome == .confirmed)
        #expect(frontmost.reads == 4)  // the flicker cost us the streak
    }

    @Test("Frontmost match while target app is not yet active waits until target is ready")
    func waitsUntilTargetIsActive() async {
        let frontmost = Frontmost([501, 501, 501])
        var readyChecks = 0
        let outcome = await restorer(
            frontmost,
            isTargetReady: { _ in
                readyChecks += 1
                return readyChecks >= 2
            }
        ).restore(to: 501)

        #expect(outcome == .confirmed)
        #expect(frontmost.reads == 3)
        #expect(readyChecks == 3)
    }

    @Test("Focus confirmation logs diagnostic fields")
    func logsDiagnosticsOnConfirm() async {
        let frontmost = Frontmost([501, 501])
        let recorder = LogRecorder()
        let outcome = await restorer(
            frontmost,
            log: { recorder.record($0) }
        ).restore(to: 501)

        #expect(outcome == .confirmed)
        let messages = recorder.entries
        #expect(messages.contains { $0.contains("Focus activation requested: target_pid=501") })
        #expect(messages.contains {
            $0.contains("Focus confirmed: target_pid=501")
                && $0.contains("ax_window=true")
                && $0.contains("ax_role=AXTextArea")
                && $0.contains("ax_err=0")
        })
    }

    @Test("A target that never returns times out with the actual frontmost pid")
    func timesOut() async {
        let frontmost = Frontmost([999])
        let outcome = await restorer(frontmost, timeout: 0.05).restore(to: 501)

        #expect(outcome == .timedOut(frontmostPid: 999))
    }

    @Test("A nil frontmost never counts as a match")
    func nilFrontmostNeverMatches() async {
        let frontmost = Frontmost([nil])
        let outcome = await restorer(frontmost, timeout: 0.05).restore(to: 501)

        #expect(outcome == .timedOut(frontmostPid: nil))
    }

    @Test("No captured pid means no injection attempt", arguments: [nil, pid_t(0)] as [pid_t?])
    func missingPid(_ pid: pid_t?) async {
        let frontmost = Frontmost([501, 501])
        let outcome = await restorer(frontmost).restore(to: pid)

        #expect(outcome == .targetUnavailable)
        #expect(frontmost.reads == 0)  // never even polled
    }

    @Test("A target process that has exited is reported, not waited on")
    func targetNoLongerRunning() async {
        let frontmost = Frontmost([501, 501])
        let outcome = await restorer(frontmost, activates: false).restore(to: 501)

        #expect(outcome == .targetUnavailable)
        #expect(frontmost.reads == 0)
    }
}

private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ message: String) {
        lock.withLock { storage.append(message) }
    }

    var entries: [String] {
        lock.withLock { storage }
    }
}
