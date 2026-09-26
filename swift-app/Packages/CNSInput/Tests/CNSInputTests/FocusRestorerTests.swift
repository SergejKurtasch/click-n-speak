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
        timeout: TimeInterval = 0.5
    ) -> FocusRestorer {
        FocusRestorer(
            timeout: timeout,
            poll: 0.005,
            activate: { _ in activates },
            frontmostPid: { frontmost.next() }
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
