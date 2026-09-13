import Foundation

public enum RuntimeServiceKind: String, Sendable, Hashable, Codable {
    case local
    case cloud
    case disabled
}

public enum RuntimeReadiness: String, Sendable, Hashable, Codable {
    case ready
    case unavailable
    case disabled
}

public struct TranscriberDescriptor: Sendable, Hashable, Codable {
    public var backend: String
    public var modelID: String
    public var kind: RuntimeServiceKind
    public var readiness: RuntimeReadiness

    public init(
        backend: String,
        modelID: String,
        kind: RuntimeServiceKind,
        readiness: RuntimeReadiness = .ready
    ) {
        self.backend = backend
        self.modelID = modelID
        self.kind = kind
        self.readiness = readiness
    }

    public static let unavailable = TranscriberDescriptor(
        backend: "none", modelID: "none", kind: .disabled, readiness: .unavailable
    )
}

public struct AiEditorDescriptor: Sendable, Hashable, Codable {
    public var backend: String
    public var modelID: String?
    public var kind: RuntimeServiceKind
    public var readiness: RuntimeReadiness

    public init(
        backend: String,
        modelID: String?,
        kind: RuntimeServiceKind,
        readiness: RuntimeReadiness = .ready
    ) {
        self.backend = backend
        self.modelID = modelID
        self.kind = kind
        self.readiness = readiness
    }

    public static let disabled = AiEditorDescriptor(
        backend: "disabled", modelID: nil, kind: .disabled, readiness: .disabled
    )
}

public struct RuntimeDescriptor: Sendable, Hashable, Codable {
    public var transcriber: TranscriberDescriptor
    public var aiEditor: AiEditorDescriptor

    public init(transcriber: TranscriberDescriptor, aiEditor: AiEditorDescriptor) {
        self.transcriber = transcriber
        self.aiEditor = aiEditor
    }

    public static let unavailable = RuntimeDescriptor(
        transcriber: .unavailable,
        aiEditor: .disabled
    )
}

/// Small lock-backed snapshot for synchronous reads from nonisolated UI and
/// watchdog callbacks. Mutations remain owned by their service actors.
public final class LockedSnapshot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func get() -> Value { lock.withLock { value } }
    public func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
