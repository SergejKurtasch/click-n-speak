import Foundation

public enum RecordingSettingsError: Error, Sendable, Equatable {
    case invalidType(field: String)
    case nonFinite(field: String)
    case nonPositive(field: String)
    case invalidOrdering
}

public struct RecordingSettings: Sendable, Equatable {
    public var silenceDurationLimit: Double
    public var targetChunkDuration: Double
    public var minChunkDuration: Double
    public var maxChunkDuration: Double
    
    public init(
        silenceDurationLimit: Double = 1.0,
        targetChunkDuration: Double = 10.0,
        minChunkDuration: Double = 2.0,
        maxChunkDuration: Double = 20.0
    ) {
        self.silenceDurationLimit = silenceDurationLimit
        self.targetChunkDuration = targetChunkDuration
        self.minChunkDuration = minChunkDuration
        self.maxChunkDuration = maxChunkDuration
    }
}
