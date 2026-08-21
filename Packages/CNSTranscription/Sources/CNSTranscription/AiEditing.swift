import Foundation

public protocol AiEditing: Sendable {
    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult
    
    func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult
    
    var isReady: Bool { get }
}

public struct RefineResult: Sendable {
    public let text: String
    public let status: RefineStatus
    
    public init(text: String, status: RefineStatus) {
        self.text = text
        self.status = status
    }
}

public enum RefineStatus: String, Sendable {
    case ok
    case unchanged
    case timeout
    case skipped
    case error
    case disabled
    case memoryPressure = "memory_pressure"
}
