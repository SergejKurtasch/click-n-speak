import Foundation

/// Lightweight editor contract shared by the session state machine and the
/// concrete local/cloud editor implementations. Keeping this in CNSCore avoids
/// forcing consumers of the protocol to compile the MLX runtime.
public protocol AiEditing: Sendable {
    var isReady: Bool { get }
    var descriptor: AiEditorDescriptor { get }

    /// Loads and validates any resources before activation. Production runtime
    /// preparation must finish before the editor router publishes the service.
    func prepare() async throws

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

    func preWarm(languages: [String]?, force: Bool) async -> PrewarmResult
    func stop() async
}

public extension AiEditing {
    var descriptor: AiEditorDescriptor { .disabled }
    func prepare() async throws {}
    func preWarm(languages: [String]?, force: Bool) async -> PrewarmResult { .skipped }
    func stop() async {}
}

public struct RefineResult: Sendable, Equatable {
    public let text: String
    public let status: RefineStatus

    public init(text: String, status: RefineStatus) {
        self.text = text
        self.status = status
    }
}

public enum RefineStatus: String, Sendable, Equatable, CaseIterable {
    case ok
    case unchanged
    case timeout
    case skipped
    case error
    case disabled
    /// Dataset-compatible explicit reason. It is operationally a skip, not a
    /// disabled editor: the same local editor may run on the next request.
    case memoryPressure = "memory_pressure"
}
