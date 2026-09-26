import Foundation
import XCTest
@testable import CNSCore

@MainActor
final class PermissionServiceTests: XCTestCase {
    func testSetupFlagUsesInjectedURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let setupURL = directory.appendingPathComponent("setup_done")
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = SystemPermissionService(setupDoneURL: setupURL)
        XCTAssertFalse(service.isSetupDone())

        try service.markSetupDone()

        XCTAssertTrue(service.isSetupDone())
        XCTAssertTrue(FileManager.default.fileExists(atPath: setupURL.path))

        try service.resetSetup()
        XCTAssertFalse(service.isSetupDone())
    }

    func testResetMissingSetupFlagIsIdempotent() throws {
        let setupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("setup_done")
        let service = SystemPermissionService(setupDoneURL: setupURL)

        XCTAssertNoThrow(try service.resetSetup())
        XCTAssertFalse(service.isSetupDone())
    }
}
