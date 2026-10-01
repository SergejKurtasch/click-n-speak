import Foundation
import XCTest
@testable import CNSCore

private final class RecoveryEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }

    var events: [String] { lock.withLock { storage } }
}

private final class ScriptedTransactionStore: UpdateTransactionStoring, @unchecked Sendable {
    private let eventLog: RecoveryEventLog
    private let failOnSave: Int?
    private var saveCount = 0
    private var record: UpdateSwapTransactionRecord

    init(
        record: UpdateSwapTransactionRecord,
        eventLog: RecoveryEventLog,
        failOnSave: Int? = nil
    ) {
        self.record = record
        self.eventLog = eventLog
        self.failOnSave = failOnSave
    }

    func load(from url: URL) throws -> UpdateSwapTransactionRecord { record }

    func save(_ record: UpdateSwapTransactionRecord, to url: URL) throws {
        saveCount += 1
        eventLog.append("save:\(record.phase.rawValue)")
        if saveCount == failOnSave { throw CocoaError(.fileWriteUnknown) }
        self.record = record
    }
}

private final class LoggingRecoveryFiles: UpdateFileOperating, @unchecked Sendable {
    private let system = SystemUpdateFileOperator()
    private let eventLog: RecoveryEventLog

    init(eventLog: RecoveryEventLog) {
        self.eventLog = eventLog
    }

    func fileExists(at url: URL) -> Bool { system.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try system.createDirectory(at: url) }
    func replaceItem(at target: URL, with staged: URL, backup: URL) throws {
        try system.replaceItem(at: target, with: staged, backup: backup)
    }
    func moveItem(at source: URL, to destination: URL) throws {
        eventLog.append("move:\(source.lastPathComponent)")
        try system.moveItem(at: source, to: destination)
    }
    func copyItem(at source: URL, to destination: URL) throws {
        try system.copyItem(at: source, to: destination)
    }
    func removeItem(at url: URL) throws {
        eventLog.append("remove:\(url.lastPathComponent)")
        try system.removeItem(at: url)
    }
}

final class UpdateTransactionRecoveryTests: XCTestCase {
    func testStructuredAcknowledgementBindsTokenCandidateAndExactProcess() {
        let candidate = UpdateCandidateIdentity(
            version: "2.0.0",
            build: "200",
            archiveSHA256: String(repeating: "a", count: 64),
            executableSHA256: String(repeating: "d", count: 64)
        )
        let acknowledgement = UpdateLaunchAcknowledgement(
            token: "token",
            candidate: candidate,
            processID: 73,
            status: .ready
        )

        XCTAssertTrue(acknowledgement.matches(token: "token", candidate: candidate, processID: 73))
        XCTAssertFalse(acknowledgement.matches(token: "other", candidate: candidate, processID: 73))
        XCTAssertFalse(acknowledgement.matches(token: "token", candidate: candidate, processID: 74))
        XCTAssertFalse(acknowledgement.matches(
            token: "token",
            candidate: UpdateCandidateIdentity(
                version: "2.0.1",
                build: "201",
                archiveSHA256: String(repeating: "b", count: 64),
                executableSHA256: String(repeating: "e", count: 64)
            ),
            processID: 73
        ))
    }

    func testLaunchReadinessRequiresBootstrapLoopAndLock() {
        XCTAssertEqual(
            UpdateLaunchReadinessPolicy.status(
                configBootstrapped: true,
                appRunLoopReady: true,
                instanceLockHeld: true,
                setupPending: false,
                runtimeCanRecord: true
            ),
            .ready
        )
        XCTAssertEqual(
            UpdateLaunchReadinessPolicy.status(
                configBootstrapped: true,
                appRunLoopReady: true,
                instanceLockHeld: true,
                setupPending: true,
                runtimeCanRecord: false
            ),
            .setupPending
        )
        XCTAssertNil(UpdateLaunchReadinessPolicy.status(
            configBootstrapped: true,
            appRunLoopReady: true,
            instanceLockHeld: true,
            setupPending: false,
            runtimeCanRecord: false
        ))
        XCTAssertNil(UpdateLaunchReadinessPolicy.status(
            configBootstrapped: true,
            appRunLoopReady: false,
            instanceLockHeld: true,
            setupPending: true,
            runtimeCanRecord: false
        ))
    }

    func testPreparedRecoveryDiscardsOnlyStagedCandidate() throws {
        let fixture = try makeRecoveryFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let eventLog = RecoveryEventLog()
        let store = ScriptedTransactionStore(record: fixture.record, eventLog: eventLog)
        let recovery = UpdateTransactionRecovery(
            store: store,
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .discardedPreparedCandidate)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
        XCTAssertEqual(eventLog.events, [
            "save:rollbackPending",
            "save:rolledBack",
            "remove:\(fixture.staged.lastPathComponent)",
        ])
    }

    func testPreparedRecoveryRecordFailurePreservesStagedCandidate() throws {
        let fixture = try makeRecoveryFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(
                record: fixture.record,
                eventLog: eventLog,
                failOnSave: 2
            ),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        XCTAssertThrowsError(try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staged.path))
        XCTAssertEqual(eventLog.events, ["save:rollbackPending", "save:rolledBack"])
    }

    func testInstalledRecoveryRecordsFinalizingBeforeDeletingBackup() throws {
        let fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let eventLog = RecoveryEventLog()
        let store = ScriptedTransactionStore(record: fixture.record, eventLog: eventLog)
        let recovery = UpdateTransactionRecovery(
            store: store,
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .finalizedReplacement)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertEqual(eventLog.events, [
            "save:launchAcknowledged",
            "save:finalizing",
            "remove:\(fixture.backup.lastPathComponent)",
            "save:finalized",
        ])
    }

    func testInstallingRecoveryRecognizesCompletedAtomicReplacement() throws {
        var fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.record.phase = .installing
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: fixture.record, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .finalizedReplacement)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
    }

    func testInstallingRecoveryAbortsWhenAtomicReplacementDidNotRun() throws {
        var fixture = try makeRecoveryFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.record.phase = .installing
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: fixture.record, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: UpdateCandidateIdentity(
                version: "1.0.0",
                build: "100",
                archiveSHA256: String(repeating: "0", count: 64),
                executableSHA256: String(repeating: "1", count: 64)
            ),
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .completedRollback)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    func testRecordFailureBeforeFinalizePreservesTargetAndBackup() throws {
        let fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let eventLog = RecoveryEventLog()
        let store = ScriptedTransactionStore(
            record: fixture.record,
            eventLog: eventLog,
            failOnSave: 2
        )
        let recovery = UpdateTransactionRecovery(
            store: store,
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        XCTAssertThrowsError(try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        ))
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.backup, encoding: .utf8), "old")
        XCTAssertEqual(eventLog.events, ["save:launchAcknowledged", "save:finalizing"])
    }

    func testAcknowledgedRecoveryResumesFinalizeWithoutReAcknowledging() throws {
        var fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.record.phase = .launchAcknowledged
        fixture.record.replacementProcessID = 73
        fixture.record.acknowledgementStatus = .setupPending
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: fixture.record, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 99,
            status: .ready
        )

        XCTAssertEqual(outcome, .finalizedReplacement)
        XCTAssertEqual(eventLog.events, [
            "save:finalizing",
            "remove:\(fixture.backup.lastPathComponent)",
            "save:finalized",
        ])
    }

    func testRollbackPendingRecoveryRecordsCompletionBeforeCandidateCleanup() throws {
        var fixture = try makeRecoveryFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.record.phase = .rollbackPending
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: fixture.record, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .completedRollback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
        XCTAssertEqual(eventLog.events, [
            "save:rolledBack",
            "remove:\(fixture.staged.lastPathComponent)",
        ])
    }

    func testRollbackPendingBeforeAtomicRollbackAcceptsNewHealthyLaunch() throws {
        var fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.record.phase = .rollbackPending
        fixture.record.failure = .acknowledgementTimedOut
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: fixture.record, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 99,
            status: .ready
        )

        XCTAssertEqual(outcome, .finalizedReplacement)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertEqual(eventLog.events, [
            "save:launchAcknowledged",
            "save:finalizing",
            "remove:\(fixture.backup.lastPathComponent)",
            "save:finalized",
        ])
    }

    func testRollbackPendingAfterAtomicRollbackCompletesOldLaunchCleanup() throws {
        var fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try RecoverableAppSwap().rollback(
            target: fixture.target,
            backup: fixture.backup,
            failedCandidate: URL(fileURLWithPath: fixture.record.failedCandidatePath!)
        )
        fixture.record.phase = .rollbackPending
        fixture.record.failure = .launchFailed
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: fixture.record, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: UpdateCandidateIdentity(
                version: "1.0.0",
                build: "100",
                archiveSHA256: String(repeating: "0", count: 64),
                executableSHA256: String(repeating: "1", count: 64)
            ),
            currentProcessID: 101,
            status: .ready
        )

        XCTAssertEqual(outcome, .completedRollback)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.failedCandidatePath!))
        XCTAssertEqual(eventLog.events, [
            "save:rolledBack",
            "remove:\(URL(fileURLWithPath: fixture.record.failedCandidatePath!).lastPathComponent)",
        ])
    }

    func testMismatchedCandidateDefersInstalledRecovery() throws {
        let fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: fixture.record, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: UpdateCandidateIdentity(
                version: "2.0.0",
                build: "200",
                archiveSHA256: String(repeating: "a", count: 64),
                executableSHA256: String(repeating: "f", count: 64)
            ),
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(eventLog.events.isEmpty)
    }

    func testRecoveryDefersBackupOutsideInstallDirectory() throws {
        let fixture = try makeRecoveryFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let outsideBackup = outsideRoot.appendingPathComponent("backup.app")
        try "unrelated".write(to: outsideBackup, atomically: true, encoding: .utf8)
        let unsafeRecord = UpdateSwapTransactionRecord(
            token: fixture.record.token,
            transactionID: fixture.record.transactionID,
            targetPath: fixture.record.targetPath,
            backupPath: outsideBackup.path,
            stagedPath: fixture.record.stagedPath,
            failedCandidatePath: fixture.record.failedCandidatePath,
            acknowledgementPath: fixture.record.acknowledgementPath,
            candidate: fixture.record.candidate,
            phase: .installed
        )
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: unsafeRecord, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(try String(contentsOf: outsideBackup, encoding: .utf8), "unrelated")
        XCTAssertTrue(eventLog.events.isEmpty)
    }

    func testRecoveryNeverTreatsCurrentApplicationAsDisposableCandidate() throws {
        let fixture = try makeRecoveryFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unsafeRecord = UpdateSwapTransactionRecord(
            token: fixture.record.token,
            transactionID: fixture.record.transactionID,
            targetPath: fixture.record.targetPath,
            backupPath: fixture.record.backupPath,
            stagedPath: fixture.target.path,
            failedCandidatePath: fixture.record.failedCandidatePath,
            acknowledgementPath: fixture.record.acknowledgementPath,
            candidate: fixture.record.candidate,
            phase: .prepared
        )
        let eventLog = RecoveryEventLog()
        let recovery = UpdateTransactionRecovery(
            store: ScriptedTransactionStore(record: unsafeRecord, eventLog: eventLog),
            files: LoggingRecoveryFiles(eventLog: eventLog)
        )

        let outcome = try recovery.recover(
            recordURL: fixture.recordURL,
            currentApplication: fixture.target,
            currentCandidate: fixture.candidate,
            currentProcessID: 73,
            status: .ready
        )

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertTrue(eventLog.events.isEmpty)
    }

    private func makeRecoveryFixture(installed: Bool) throws -> (
        root: URL,
        recordURL: URL,
        staged: URL,
        target: URL,
        backup: URL,
        candidate: UpdateCandidateIdentity,
        record: UpdateSwapTransactionRecord
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transactionID = UUID().uuidString
        let token = UUID().uuidString
        let staged = root.appendingPathComponent(".Click-n-speak.update-\(transactionID).app")
        let target = root.appendingPathComponent("target.app")
        let backup = root.appendingPathComponent(".Click-n-speak.backup-\(transactionID).app")
        let failed = root.appendingPathComponent(".click-n-speak-failed-\(token).app")
        let ack = root.appendingPathComponent("ack-\(transactionID)")
        let recordURL = root.appendingPathComponent("transaction-\(transactionID).json")
        let candidate = UpdateCandidateIdentity(
            version: "2.0.0",
            build: "200",
            archiveSHA256: String(repeating: "a", count: 64),
            executableSHA256: String(repeating: "d", count: 64)
        )
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try "new".write(to: staged, atomically: true, encoding: .utf8)
        if installed {
            try FileManager.default.moveItem(at: target, to: backup)
            try FileManager.default.moveItem(at: staged, to: target)
        }
        let record = UpdateSwapTransactionRecord(
            token: token,
            transactionID: transactionID,
            targetPath: target.path,
            backupPath: backup.path,
            stagedPath: staged.path,
            failedCandidatePath: failed.path,
            acknowledgementPath: ack.path,
            candidate: candidate,
            phase: installed ? .installed : .prepared
        )
        return (root, recordURL, staged, target, backup, candidate, record)
    }
}
