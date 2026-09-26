import XCTest
@testable import CNSCore

@MainActor
private final class FakeAutostartService: AutostartServicing {
    var currentStatus: AutostartSystemStatus
    var statusAfterRegister: AutostartSystemStatus = .enabled
    var statusAfterUnregister: AutostartSystemStatus = .disabled
    var operationError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(_ status: AutostartSystemStatus) {
        currentStatus = status
    }

    func status() -> AutostartSystemStatus { currentStatus }

    func register() throws {
        registerCount += 1
        if let operationError { throw operationError }
        currentStatus = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let operationError { throw operationError }
        currentStatus = statusAfterUnregister
    }
}

@MainActor
final class AutostartTests: XCTestCase {
    func testEnableRequeriesSystemAndReturnsEnabled() throws {
        let service = FakeAutostartService(.disabled)
        XCTAssertEqual(try Autostart.setEnabled(true, using: service), .enabled)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(Autostart.isEnabled(using: service))
    }

    func testAlreadyEnabledDoesNotRegisterTwice() throws {
        let service = FakeAutostartService(.enabled)
        XCTAssertEqual(try Autostart.setEnabled(true, using: service), .enabled)
        XCTAssertEqual(service.registerCount, 0)
    }

    func testRequiresApprovalIsSurfacedWithoutPretendingEnabled() throws {
        let service = FakeAutostartService(.disabled)
        service.statusAfterRegister = .requiresApproval
        XCTAssertEqual(try Autostart.setEnabled(true, using: service), .requiresApproval)
        XCTAssertFalse(Autostart.isEnabled(using: service))
    }

    func testDisableAcceptsNotFoundAsSystemTruth() throws {
        let service = FakeAutostartService(.enabled)
        service.statusAfterUnregister = .notFound
        XCTAssertEqual(try Autostart.setEnabled(false, using: service), .notFound)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    func testRegistrationFailurePropagates() {
        let service = FakeAutostartService(.disabled)
        service.operationError = CocoaError(.fileWriteNoPermission)
        XCTAssertThrowsError(try Autostart.setEnabled(true, using: service))
        XCTAssertEqual(service.currentStatus, .disabled)
    }

    func testUnexpectedFinalStateFails() {
        let service = FakeAutostartService(.disabled)
        service.statusAfterRegister = .notFound
        XCTAssertThrowsError(try Autostart.setEnabled(true, using: service))
    }
}
