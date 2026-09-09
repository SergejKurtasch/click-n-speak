import Foundation

public enum RecorderError: Error {
    /// The previous stream never finished tearing down — Core Audio is wedged and
    /// the app restarts instead of opening a stream that would capture nothing.
    case previousStreamStuck
}

/// What the app did with a term the user added from the popup.
public enum AddTermResult: Sendable, Equatable {
    /// Added; `message` overrides the default "Added: {term}" toast when non-nil.
    case added(message: String?)
    case alreadyExists
}

/// Toast strings for the Add-to-Dictionary flow, supplied by the caller so the
/// panel stays free of i18n lookups.
public struct DictionaryToasts: Sendable {
    public var addedTemplate: String
    public var invalidTerm: String
    public var alreadyExists: String

    public init(
        addedTemplate: String = "Added: {term}",
        invalidTerm: String = "Not a valid term",
        alreadyExists: String = "Already exists in dictionary"
    ) {
        self.addedTemplate = addedTemplate
        self.invalidTerm = invalidTerm
        self.alreadyExists = alreadyExists
    }
}

/// The popup surface the session drives. `PreviewPanel` conforms; tests use a
/// recording double, which is why this exists at all.
@MainActor
public protocol PopupPresenting: AnyObject {
    var isShowingInteractive: Bool { get }
    func show(title: String)
    func updateStatus(_ title: String)
    func updateText(_ text: String)
    func appendText(_ text: String)
    /// Enables or disables confirm/cancel without destroying editor state.
    func setDecisionEnabled(_ enabled: Bool)
    /// Shows a persistent warning without replacing the editable transcript.
    func showIncompleteWarning(_ message: String)
    func hide(delay: TimeInterval)
    func showInteractive(
        text: String,
        title: String,
        toasts: DictionaryToasts,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onAddToDictionary: ((String) -> AddTermResult)?
    )
}

public struct AudioCallbacks: Sendable {
    public var onChunk: @Sendable ([Float]) -> Void
    public var onFinal: @Sendable ([Float]?) -> Void

    public init(onChunk: @escaping @Sendable ([Float]) -> Void = { _ in }, onFinal: @escaping @Sendable ([Float]?) -> Void = { _ in }) {
        self.onChunk = onChunk
        self.onFinal = onFinal
    }
}

/// Microphone capture. `AudioRecorder` conforms.
public protocol AudioCapturing: Sendable {
    var isRecording: Bool { get }
    func start(callbacks: AudioCallbacks) async throws
    /// Stop accepting samples, drain every sample already owned by the capture
    /// pipeline, and emit the final callback before returning.
    func stop() async
}

/// Getting confirmed text into the app the user dictated from: restore focus,
/// then insert. Implemented by `SystemTextDelivery`.
public enum TextDeliveryFailure: String, Sendable, Equatable {
    case targetUnavailable
    case focusTimedOut
    case accessibilityDenied
    case injectionFailed
}

public enum TextDeliveryOutcome: Sendable, Equatable {
    case delivered
    case failed(TextDeliveryFailure)
    /// Cancellation was observed before any insertion side effect was attempted.
    case cancelled

    public var succeeded: Bool {
        self == .delivered
    }

    public var telemetryValue: String {
        switch self {
        case .delivered: "delivered"
        case let .failed(failure): failure.rawValue
        case .cancelled: "cancelled"
        }
    }
}

@MainActor
public protocol TextDelivering {
    /// A notification or clipboard fallback is never reported as delivery.
    func deliver(_ text: String, to pid: pid_t?) async -> TextDeliveryOutcome
}

/// Where the frontmost application's pid comes from. Injected so tests can
/// pretend another app was in front.
@MainActor
public protocol FrontmostAppProviding: Sendable {
    func frontmostPid() -> pid_t?
}
