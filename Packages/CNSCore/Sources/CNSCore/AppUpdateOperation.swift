import Foundation

public struct StagedUpdateHandle: Sendable, Equatable {
    public let operationID: UUID
    public let version: String
    
    public init(operationID: UUID, version: String) {
        self.operationID = operationID
        self.version = version
    }
}

public enum AppUpdateStage: String, Sendable {
    case downloading, verifyingArchive, staging, verifyingCandidate, ready
}

public struct AppUpdateProgress: Sendable {
    public let stage: AppUpdateStage
    public let fraction: Double?
    
    public init(stage: AppUpdateStage, fraction: Double?) {
        self.stage = stage
        self.fraction = fraction
    }
}

public struct UpdateInstallationHandle: Sendable, Equatable {
    public let transactionID: UUID
    public let operationID: UUID
    
    public init(transactionID: UUID, operationID: UUID) {
        self.transactionID = transactionID
        self.operationID = operationID
    }
}
