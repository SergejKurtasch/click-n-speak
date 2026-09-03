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
}
