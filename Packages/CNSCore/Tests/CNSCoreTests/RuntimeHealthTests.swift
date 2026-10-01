import XCTest
@testable import CNSCore

@MainActor
final class RuntimeHealthTests: XCTestCase {
    func testInitialization() {
        let monitor = TranscriberHealthMonitor()
        XCTAssertNotNil(monitor)
    }

    func testColdStartDecode() {
        let monitor = TranscriberHealthMonitor()
        let decision = monitor.recordDecode(durationSeconds: 5.0, coldStart: true)
        XCTAssertFalse(decision.shouldRestart)
    }

    func testWarmStartDecode() {
        let monitor = TranscriberHealthMonitor()
        let decision = monitor.recordDecode(durationSeconds: 0.5, coldStart: false)
        XCTAssertFalse(decision.shouldRestart)
    }

    func testSkippedPrewarmDoesNotRequestRestart() {
        let monitor = TranscriberHealthMonitor()

        let decision = monitor.recordPrewarm(
            durationSeconds: 12,
            outcome: .skipped,
            now: 100
        )

        XCTAssertFalse(decision.shouldRestart)
        XCTAssertNil(decision.reason)
    }

    func testFailedPrewarmRequestsRestart() {
        let monitor = TranscriberHealthMonitor()

        let decision = monitor.recordPrewarm(
            durationSeconds: 0.5,
            outcome: .failed,
            now: 100
        )

        XCTAssertTrue(decision.shouldRestart)
        XCTAssertEqual(decision.reason, "prewarm_failed")
    }

    func testSeverelySlowSuccessfulPrewarmRequestsRestart() {
        let monitor = TranscriberHealthMonitor(severePrewarmSeconds: 10)

        let decision = monitor.recordPrewarm(
            durationSeconds: 10,
            outcome: .warmed,
            now: 100
        )

        XCTAssertTrue(decision.shouldRestart)
        XCTAssertEqual(decision.reason, "prewarm_severely_slow")
    }
}
