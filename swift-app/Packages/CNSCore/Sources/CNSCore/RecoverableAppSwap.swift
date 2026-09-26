import Foundation

public protocol UpdateFileOperating: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func replaceItem(at target: URL, with staged: URL, backup: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

public struct SystemUpdateFileOperator: UpdateFileOperating {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func replaceItem(at target: URL, with staged: URL, backup: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            target,
            withItemAt: staged,
            backupItemName: backup.lastPathComponent,
            options: [.withoutDeletingBackupItem]
        )
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public enum AppSwapError: LocalizedError, Sendable, Equatable {
    case stagedApplicationMissing
    case targetAlreadyMissing
    case backupCollision
    case installationFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .stagedApplicationMissing: "The staged application is missing"
        case .targetAlreadyMissing: "The currently installed application is missing"
        case .backupCollision: "A previous update backup still exists"
        case .installationFailed: "The replacement application could not be installed"
        case .rollbackFailed: "The previous application could not be restored"
        }
    }
}

public struct UpdateCandidateIdentity: Codable, Sendable, Equatable {
    public let version: String
    public let build: String
    public let archiveSHA256: String
    public let executableSHA256: String

    public init(
        version: String,
        build: String,
        archiveSHA256: String,
        executableSHA256: String
    ) {
        self.version = version
        self.build = build
        self.archiveSHA256 = archiveSHA256.lowercased()
        self.executableSHA256 = executableSHA256.lowercased()
    }
}

public enum UpdateLaunchStatus: String, Codable, Sendable, Equatable {
    case ready
    case setupPending
}

public struct UpdateLaunchAcknowledgement: Codable, Sendable, Equatable {
    public let token: String
    public let candidate: UpdateCandidateIdentity
    public let processID: Int32
    public let status: UpdateLaunchStatus

    public init(
        token: String,
        candidate: UpdateCandidateIdentity,
        processID: Int32,
        status: UpdateLaunchStatus
    ) {
        self.token = token
        self.candidate = candidate
        self.processID = processID
        self.status = status
    }

    public func matches(
        token: String,
        candidate: UpdateCandidateIdentity,
        processID: Int32
    ) -> Bool {
        self.token == token && self.candidate == candidate && self.processID == processID
    }
}

public enum UpdateLaunchReadinessPolicy {
    public static func status(
        configBootstrapped: Bool,
        appRunLoopReady: Bool,
        instanceLockHeld: Bool,
        setupPending: Bool,
        runtimeCanRecord: Bool
    ) -> UpdateLaunchStatus? {
        guard configBootstrapped, appRunLoopReady, instanceLockHeld else { return nil }
        if setupPending { return .setupPending }
        return runtimeCanRecord ? .ready : nil
    }
}

public enum UpdateTransactionFailure: String, Codable, Sendable, Equatable {
    case parentDidNotExit
    case installFailed
    case launchFailed
    case acknowledgementTimedOut
    case replacementDidNotExit
    case rollbackFailed
    case finalizeFailed
}

public struct UpdateSwapTransactionRecord: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case prepared
        case installing
        case installed
        case launched
        case launchAcknowledged
        case finalizing
        case finalized
        case rollbackPending
        case acknowledged
        case rolledBack
    }

    public let token: String
    public let transactionID: String?
    public let targetPath: String
    public let backupPath: String
    public let stagedPath: String?
    public let failedCandidatePath: String?
    public let acknowledgementPath: String?
    public let candidate: UpdateCandidateIdentity?
    public let createdAt: Date
    public var phase: Phase
    public var replacementProcessID: Int32?
    public var acknowledgementStatus: UpdateLaunchStatus?
    public var failure: UpdateTransactionFailure?

    public init(
        token: String,
        transactionID: String? = nil,
        targetPath: String,
        backupPath: String,
        stagedPath: String? = nil,
        failedCandidatePath: String? = nil,
        acknowledgementPath: String? = nil,
        candidate: UpdateCandidateIdentity? = nil,
        createdAt: Date = Date(),
        phase: Phase,
        replacementProcessID: Int32? = nil,
        acknowledgementStatus: UpdateLaunchStatus? = nil,
        failure: UpdateTransactionFailure? = nil
    ) {
        self.token = token
        self.transactionID = transactionID
        self.targetPath = targetPath
        self.backupPath = backupPath
        self.stagedPath = stagedPath
        self.failedCandidatePath = failedCandidatePath
        self.acknowledgementPath = acknowledgementPath
        self.candidate = candidate
        self.createdAt = createdAt
        self.phase = phase
        self.replacementProcessID = replacementProcessID
        self.acknowledgementStatus = acknowledgementStatus
        self.failure = failure
    }
}

public protocol UpdateTransactionStoring: Sendable {
    func load(from url: URL) throws -> UpdateSwapTransactionRecord
    func save(_ record: UpdateSwapTransactionRecord, to url: URL) throws
}

public struct FileUpdateTransactionStore: UpdateTransactionStoring {
    public init() {}

    public func load(from url: URL) throws -> UpdateSwapTransactionRecord {
        try JSONDecoder().decode(UpdateSwapTransactionRecord.self, from: Data(contentsOf: url))
    }

    public func save(_ record: UpdateSwapTransactionRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.writeData(try encoder.encode(record), to: url)
    }
}

public enum UpdateRecoveryOutcome: Sendable, Equatable {
    case discardedPreparedCandidate
    case completedRollback
    case finalizedReplacement
    case alreadyFinalized
    case deferred
}

public struct UpdateTransactionRecovery: Sendable {
    private let store: any UpdateTransactionStoring
    private let files: any UpdateFileOperating

    public init(
        store: any UpdateTransactionStoring = FileUpdateTransactionStore(),
        files: any UpdateFileOperating = SystemUpdateFileOperator()
    ) {
        self.store = store
        self.files = files
    }

    public func recover(
        recordURL: URL,
        currentApplication: URL,
        currentCandidate: UpdateCandidateIdentity,
        currentProcessID: Int32,
        status: UpdateLaunchStatus
    ) throws -> UpdateRecoveryOutcome {
        var record = try store.load(from: recordURL)
        let target = URL(fileURLWithPath: record.targetPath).standardizedFileURL
        let backup = URL(fileURLWithPath: record.backupPath).standardizedFileURL
        let installDirectory = target.deletingLastPathComponent()
        let staged = record.stagedPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let failedCandidate = record.failedCandidatePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let acknowledgement = record.acknowledgementPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        guard let transactionID = record.transactionID,
              UUID(uuidString: transactionID) != nil,
              UUID(uuidString: record.token) != nil,
              recordURL.lastPathComponent == "transaction-\(transactionID).json",
              target == currentApplication.standardizedFileURL,
              backup.deletingLastPathComponent() == installDirectory,
              staged.map({ $0.deletingLastPathComponent() == installDirectory }) ?? true,
              failedCandidate.map({ $0.deletingLastPathComponent() == installDirectory }) ?? true,
              backup != target,
              staged.map({ $0 != target && $0 != backup }) ?? true,
              failedCandidate.map({ failedURL in
                  failedURL != target
                      && failedURL != backup
                      && (staged.map { failedURL != $0 } ?? true)
              }) ?? true,
              backup.lastPathComponent == ".Click-n-speak.backup-\(transactionID).app",
              staged?.lastPathComponent == ".Click-n-speak.update-\(transactionID).app",
              failedCandidate?.lastPathComponent == ".click-n-speak-failed-\(record.token).app",
              acknowledgement?.deletingLastPathComponent()
                  == recordURL.deletingLastPathComponent(),
              acknowledgement?.lastPathComponent == "ack-\(transactionID)" else {
            return .deferred
        }

        switch record.phase {
        case .prepared:
            guard let staged,
                  files.fileExists(at: target),
                  !files.fileExists(at: backup) else {
                return .deferred
            }
            record.phase = .rollbackPending
            try store.save(record, to: recordURL)
            record.phase = .rolledBack
            try store.save(record, to: recordURL)
            try discardTransactionCandidates(staged: staged, failedCandidate: failedCandidate)
            return .discardedPreparedCandidate

        case .installing:
            if record.candidate == currentCandidate,
               files.fileExists(at: target),
               files.fileExists(at: backup) {
                record.phase = .launchAcknowledged
                record.replacementProcessID = currentProcessID
                record.acknowledgementStatus = status
                record.failure = nil
                try store.save(record, to: recordURL)
                return try finalize(record: record, recordURL: recordURL, backup: backup)
            }
            guard files.fileExists(at: target),
                  !files.fileExists(at: backup),
                  let staged,
                  files.fileExists(at: staged) else {
                return .deferred
            }
            record.phase = .rollbackPending
            try store.save(record, to: recordURL)
            record.phase = .rolledBack
            try store.save(record, to: recordURL)
            try discardTransactionCandidates(staged: staged, failedCandidate: failedCandidate)
            return .completedRollback

        case .installed, .launched:
            guard record.candidate == currentCandidate else { return .deferred }
            record.phase = .launchAcknowledged
            record.replacementProcessID = currentProcessID
            record.acknowledgementStatus = status
            record.failure = nil
            try store.save(record, to: recordURL)
            return try finalize(record: record, recordURL: recordURL, backup: backup)

        case .launchAcknowledged, .acknowledged, .finalizing:
            guard record.candidate == currentCandidate else { return .deferred }
            if !files.fileExists(at: backup) {
                record.phase = .finalized
                record.failure = nil
                try store.save(record, to: recordURL)
                return .alreadyFinalized
            }
            return try finalize(record: record, recordURL: recordURL, backup: backup)

        case .finalized:
            return .alreadyFinalized
        case .rollbackPending:
            if record.candidate == currentCandidate,
               files.fileExists(at: target),
               files.fileExists(at: backup),
               failedCandidate.map({ !files.fileExists(at: $0) }) ?? true {
                record.phase = .launchAcknowledged
                record.replacementProcessID = currentProcessID
                record.acknowledgementStatus = status
                record.failure = nil
                try store.save(record, to: recordURL)
                return try finalize(record: record, recordURL: recordURL, backup: backup)
            }
            guard files.fileExists(at: target), !files.fileExists(at: backup) else {
                return .deferred
            }
            record.phase = .rolledBack
            try store.save(record, to: recordURL)
            try discardTransactionCandidates(staged: staged, failedCandidate: failedCandidate)
            return .completedRollback
        case .rolledBack:
            guard files.fileExists(at: target), !files.fileExists(at: backup) else {
                return .deferred
            }
            try discardTransactionCandidates(staged: staged, failedCandidate: failedCandidate)
            return .completedRollback
        }
    }

    private func discardTransactionCandidates(staged: URL?, failedCandidate: URL?) throws {
        for candidate in [staged, failedCandidate].compactMap({ $0 }) where files.fileExists(at: candidate) {
            try files.removeItem(at: candidate)
        }
    }

    private func finalize(
        record initialRecord: UpdateSwapTransactionRecord,
        recordURL: URL,
        backup: URL
    ) throws -> UpdateRecoveryOutcome {
        var record = initialRecord
        record.phase = .finalizing
        try store.save(record, to: recordURL)
        try RecoverableAppSwap(files: files).finalize(backup: backup)
        record.phase = .finalized
        try store.save(record, to: recordURL)
        return .finalizedReplacement
    }
}

/// Same-volume, recoverable application swap used by the signed update helper.
/// The backup remains until the replacement reports a successful launch token.
public struct RecoverableAppSwap: Sendable {
    private let files: any UpdateFileOperating

    public init(files: any UpdateFileOperating = SystemUpdateFileOperator()) {
        self.files = files
    }

    public func install(staged: URL, target: URL, backup: URL) throws {
        guard files.fileExists(at: staged) else { throw AppSwapError.stagedApplicationMissing }
        guard files.fileExists(at: target) else { throw AppSwapError.targetAlreadyMissing }
        guard !files.fileExists(at: backup) else { throw AppSwapError.backupCollision }

        do {
            try files.replaceItem(at: target, with: staged, backup: backup)
        } catch {
            throw AppSwapError.installationFailed
        }
    }

    public func rollback(target: URL, backup: URL, failedCandidate: URL) throws {
        if !files.fileExists(at: backup) {
            guard files.fileExists(at: target), files.fileExists(at: failedCandidate) else {
                throw AppSwapError.rollbackFailed
            }
            return
        }

        if !files.fileExists(at: target) {
            guard files.fileExists(at: failedCandidate) else {
                throw AppSwapError.rollbackFailed
            }
            do {
                try files.moveItem(at: backup, to: target)
            } catch {
                throw AppSwapError.rollbackFailed
            }
            return
        }
        guard !files.fileExists(at: failedCandidate) else {
            throw AppSwapError.rollbackFailed
        }
        do {
            try files.replaceItem(at: target, with: backup, backup: failedCandidate)
        } catch {
            throw AppSwapError.rollbackFailed
        }
    }

    public func discardFailedCandidate(at failedCandidate: URL) throws {
        if files.fileExists(at: failedCandidate) {
            try files.removeItem(at: failedCandidate)
        }
    }

    public func finalize(backup: URL) throws {
        if files.fileExists(at: backup) {
            try files.removeItem(at: backup)
        }
    }
}
