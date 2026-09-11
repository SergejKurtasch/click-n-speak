import Foundation
import XCTest
@testable import CNSCore

private final class ScriptedUpdateProcessOperator: UpdateProcessOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var waitResults: [Bool]
    private var launchResults: [Int32?]
    private(set) var terminationRequests: [Int32] = []
    private(set) var launches: [(URL, [String])] = []

    init(waitResults: [Bool], launchResults: [Int32?] = []) {
        self.waitResults = waitResults
        self.launchResults = launchResults
    }

    func isRunning(pid: Int32) -> Bool { true }

    func requestTermination(pid: Int32) throws {
        lock.withLock {
            terminationRequests.append(pid)
        }
    }

    func waitForExit(pid: Int32, timeout: TimeInterval) async throws -> Bool {
        lock.withLock {
            waitResults.removeFirst()
        }
    }

    func launch(application: URL, arguments: [String]) async throws -> Int32 {
        try lock.withLock {
            launches.append((application, arguments))
            guard !launchResults.isEmpty,
                  let pid = launchResults.removeFirst() else {
                throw CocoaError(.executableNotLoadable)
            }
            return pid
        }
    }
}

private final class RemoveFailingUpdateFileOperator: UpdateFileOperating, @unchecked Sendable {
    private let system = SystemUpdateFileOperator()

    func fileExists(at url: URL) -> Bool { system.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try system.createDirectory(at: url) }
    func moveItem(at source: URL, to destination: URL) throws {
        try system.moveItem(at: source, to: destination)
    }
    func copyItem(at source: URL, to destination: URL) throws {
        try system.copyItem(at: source, to: destination)
    }
    func removeItem(at url: URL) throws { throw CocoaError(.fileWriteUnknown) }
}

final class UpdateProcessLifecycleTests: XCTestCase {
    func testLiveParentPreventsAnySwapMutation() async throws {
        let fixture = try makeLifecycleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = ScriptedUpdateProcessOperator(waitResults: [false])
        let lifecycle = UpdateProcessLifecycle(processes: processes)

        do {
            try await lifecycle.installAfterParentExit(
                parentPID: 41,
                timeout: 30,
                staged: fixture.staged,
                target: fixture.target,
                backup: fixture.backup
            )
            XCTFail("Expected the live parent to block installation")
        } catch let error as UpdateLifecycleError {
            XCTAssertEqual(error, .parentDidNotExit)
        }
        XCTAssertEqual(try String(contentsOf: fixture.staged, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
    }

    func testExitedParentAllowsSwap() async throws {
        let fixture = try makeLifecycleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lifecycle = UpdateProcessLifecycle(
            processes: ScriptedUpdateProcessOperator(waitResults: [true])
        )

        try await lifecycle.installAfterParentExit(
            parentPID: 41,
            timeout: 30,
            staged: fixture.staged,
            target: fixture.target,
            backup: fixture.backup
        )

        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.backup, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    func testReplacementThatDoesNotExitBlocksRollbackWithoutTouchingBundles() async throws {
        let fixture = try makeInstalledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = ScriptedUpdateProcessOperator(waitResults: [false])
        let lifecycle = UpdateProcessLifecycle(processes: processes)

        do {
            try await lifecycle.rollbackAfterReplacementExit(
                replacementPID: 73,
                timeout: 10,
                target: fixture.target,
                backup: fixture.backup,
                failedCandidate: fixture.failedCandidate
            )
            XCTFail("Expected the running replacement to block rollback")
        } catch let error as UpdateLifecycleError {
            XCTAssertEqual(error, .replacementDidNotExit)
        }
        XCTAssertEqual(processes.terminationRequests, [73])
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.backup, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.failedCandidate.path))
    }

    func testRollbackTerminatesOnlyReplacementPID() async throws {
        let fixture = try makeInstalledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = ScriptedUpdateProcessOperator(waitResults: [true])
        let lifecycle = UpdateProcessLifecycle(processes: processes)

        try await lifecycle.rollbackAfterReplacementExit(
            replacementPID: 73,
            timeout: 10,
            target: fixture.target,
            backup: fixture.backup,
            failedCandidate: fixture.failedCandidate
        )

        XCTAssertEqual(processes.terminationRequests, [73])
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: fixture.failedCandidate, encoding: .utf8), "new")
    }

    func testSuccessfulRestoredLaunchRemovesFailedCandidate() async throws {
        let fixture = try makeInstalledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = ScriptedUpdateProcessOperator(waitResults: [true], launchResults: [91])
        let lifecycle = UpdateProcessLifecycle(processes: processes)

        let restoredPID = try await lifecycle.restorePreviousApplication(
            replacementPID: 73,
            exitTimeout: 10,
            target: fixture.target,
            backup: fixture.backup,
            failedCandidate: fixture.failedCandidate
        )

        XCTAssertEqual(restoredPID, 91)
        XCTAssertEqual(processes.terminationRequests, [73])
        XCTAssertEqual(processes.launches.map(\.0), [fixture.target])
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.failedCandidate.path))
    }

    func testFailedRestoredLaunchKeepsFailedCandidateForRecovery() async throws {
        let fixture = try makeInstalledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = ScriptedUpdateProcessOperator(waitResults: [true])
        let lifecycle = UpdateProcessLifecycle(processes: processes)

        await XCTAssertThrowsErrorAsync {
            try await lifecycle.restorePreviousApplication(
                replacementPID: 73,
                exitTimeout: 10,
                target: fixture.target,
                backup: fixture.backup,
                failedCandidate: fixture.failedCandidate
            )
        }
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: fixture.failedCandidate, encoding: .utf8), "new")
    }

    func testRecoveryRetriesLaunchAfterFileRollbackAlreadyCompleted() async throws {
        let fixture = try makeInstalledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = ScriptedUpdateProcessOperator(
            waitResults: [true],
            launchResults: [nil, 91]
        )
        let lifecycle = UpdateProcessLifecycle(processes: processes)

        await XCTAssertThrowsErrorAsync {
            try await lifecycle.restorePreviousApplication(
                replacementPID: 73,
                exitTimeout: 10,
                target: fixture.target,
                backup: fixture.backup,
                failedCandidate: fixture.failedCandidate
            )
        }
        let restoredPID = try await lifecycle.restorePreviousApplication(
            replacementPID: nil,
            exitTimeout: 10,
            target: fixture.target,
            backup: fixture.backup,
            failedCandidate: fixture.failedCandidate
        )

        XCTAssertEqual(restoredPID, 91)
        XCTAssertEqual(processes.launches.map(\.0), [fixture.target, fixture.target])
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.failedCandidate.path))
    }

    func testLaunchReturnsApplicationPIDAndForwardsArguments() async throws {
        let application = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement.app")
        let processes = ScriptedUpdateProcessOperator(waitResults: [], launchResults: [73])
        let lifecycle = UpdateProcessLifecycle(processes: processes)

        let pid = try await lifecycle.launch(application: application, arguments: ["--token", "abc"])

        XCTAssertEqual(pid, 73)
        XCTAssertEqual(processes.launches.map(\.0), [application])
        XCTAssertEqual(processes.launches.first?.1, ["--token", "abc"])
    }

    func testFinalizeFailurePreservesInstalledTargetAndBackup() throws {
        let fixture = try makeInstalledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lifecycle = UpdateProcessLifecycle(
            processes: ScriptedUpdateProcessOperator(waitResults: []),
            files: RemoveFailingUpdateFileOperator()
        )

        XCTAssertThrowsError(try lifecycle.finalizeSuccessfulUpdate(backup: fixture.backup))
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.backup, encoding: .utf8), "old")
    }

    private func makeLifecycleFixture() throws -> (
        root: URL,
        staged: URL,
        target: URL,
        backup: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("staged.app")
        let target = root.appendingPathComponent("target.app")
        let backup = root.appendingPathComponent("backup.app")
        try "new".write(to: staged, atomically: true, encoding: .utf8)
        try "old".write(to: target, atomically: true, encoding: .utf8)
        return (root, staged, target, backup)
    }

    private func makeInstalledFixture() throws -> (
        root: URL,
        target: URL,
        backup: URL,
        failedCandidate: URL
    ) {
        let fixture = try makeLifecycleFixture()
        try FileManager.default.moveItem(at: fixture.target, to: fixture.backup)
        try FileManager.default.moveItem(at: fixture.staged, to: fixture.target)
        return (
            fixture.root,
            fixture.target,
            fixture.backup,
            fixture.root.appendingPathComponent("failed-candidate.app")
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
