import Foundation

public protocol UpdateFileOperating: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
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

public struct UpdateSwapTransactionRecord: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case prepared
        case installed
        case acknowledged
        case rolledBack
    }

    public let token: String
    public let targetPath: String
    public let backupPath: String
    public let createdAt: Date
    public var phase: Phase

    public init(
        token: String,
        targetPath: String,
        backupPath: String,
        createdAt: Date = Date(),
        phase: Phase
    ) {
        self.token = token
        self.targetPath = targetPath
        self.backupPath = backupPath
        self.createdAt = createdAt
        self.phase = phase
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
            try files.moveItem(at: target, to: backup)
        } catch {
            throw AppSwapError.installationFailed
        }
        do {
            try files.moveItem(at: staged, to: target)
        } catch {
            do {
                try files.moveItem(at: backup, to: target)
            } catch {
                throw AppSwapError.rollbackFailed
            }
            throw AppSwapError.installationFailed
        }
    }

    public func rollback(target: URL, backup: URL) throws {
        do {
            if files.fileExists(at: target) {
                try files.removeItem(at: target)
            }
            guard files.fileExists(at: backup) else { throw AppSwapError.rollbackFailed }
            try files.moveItem(at: backup, to: target)
        } catch {
            throw AppSwapError.rollbackFailed
        }
    }

    public func finalize(backup: URL) throws {
        if files.fileExists(at: backup) {
            try files.removeItem(at: backup)
        }
    }
}
