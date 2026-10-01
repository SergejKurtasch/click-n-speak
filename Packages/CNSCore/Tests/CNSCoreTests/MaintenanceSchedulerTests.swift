import Foundation
import XCTest
@testable import CNSCore

final class MaintenanceSchedulerTests: XCTestCase {
    func testIntervalGateRunsAtExactSixtySecondBoundary() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var gate = IntervalGate(interval: 60, lastRun: start)

        XCTAssertFalse(gate.shouldRun(now: start.addingTimeInterval(59.999)))
        XCTAssertTrue(gate.shouldRun(now: start.addingTimeInterval(60)))

        gate.markRun(now: start.addingTimeInterval(60))
        XCTAssertFalse(gate.shouldRun(now: start.addingTimeInterval(119.999)))
        XCTAssertTrue(gate.shouldRun(now: start.addingTimeInterval(120)))
    }
}
