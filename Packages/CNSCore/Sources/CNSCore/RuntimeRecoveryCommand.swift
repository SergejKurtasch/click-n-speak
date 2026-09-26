import Foundation

public enum RuntimeRecoveryKind: Sendable, Equatable {
    case download
    case redownload
    case openAPIKeys
    case selectCloudBackend
    case keepPreviousRuntime
    case retry
}

public enum RuntimeRecoveryTarget: Sendable, Equatable {
    case general
    case localModel(id: String)
    case cloudProvider(name: String)
}

public struct RuntimeRecoveryCommand: Sendable, Equatable {
    public let kind: RuntimeRecoveryKind
    public let target: RuntimeRecoveryTarget
    public let generation: Int
    
    public init(kind: RuntimeRecoveryKind, target: RuntimeRecoveryTarget, generation: Int = 0) {
        self.kind = kind
        self.target = target
        self.generation = generation
    }
}
