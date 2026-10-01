import CNSCore
import Foundation

public typealias PrewarmResult = CNSCore.PrewarmResult

/// One transcription request for an audio chunk. Fields mirror the parameters of
/// `TranscriberProcessWrapper.transcribe` in `transcriber.py`.
public struct TranscriptionRequest: Sendable {
    /// 16 kHz mono float32 samples.
    public var audio: [Float]
    /// Whisper `initial_prompt` (dictionary + recent context), or nil.
    public var initialPrompt: String?
    /// Per-language prompt overrides for multilingual language selection.
    /// Empty preserves the legacy `initialPrompt` behavior.
    public var initialPromptsByLanguage: [String: String]
    /// Allowed language codes; empty means auto-detect (no hint).
    public var allowedLanguages: [String]
    /// Whether to condition on previously decoded text.
    public var conditionOnPreviousText: Bool
    /// True for the last chunk of a session (relaxes short-chunk guards).
    public var isFinalChunk: Bool
    /// Explicit per-decode deadline. The first cold decode receives a larger
    /// budget than subsequent warm decodes.
    public var decodeTimeout: TimeInterval?

    public init(
        audio: [Float],
        initialPrompt: String? = nil,
        initialPromptsByLanguage: [String: String] = [:],
        allowedLanguages: [String] = [],
        conditionOnPreviousText: Bool = true,
        isFinalChunk: Bool = false,
        decodeTimeout: TimeInterval? = nil
    ) {
        self.audio = audio
        self.initialPrompt = initialPrompt
        self.initialPromptsByLanguage = initialPromptsByLanguage
        self.allowedLanguages = allowedLanguages
        self.conditionOnPreviousText = conditionOnPreviousText
        self.isFinalChunk = isFinalChunk
        self.decodeTimeout = decodeTimeout
    }
}

public enum TranscriptionDeadlinePolicy {
    public static let warmDecodeSeconds: TimeInterval = 30
    public static let coldDecodeSeconds: TimeInterval = 90
}

public enum TranscriptionGuardReason: String, Sendable, Equatable {
    case emptyAudio = "empty_audio"
    case tinyFinalChunk = "tiny_final_chunk"
    case silentShortChunk = "silent_short_chunk"
    case hallucination
}

public enum TranscriptionFailureKind: String, Sendable, Equatable {
    case unavailable
    case modelLoad
    case decode
    case invalidRequest
    case unauthorized
    case rateLimited
    case server
    case network
    case malformedResponse
    case unsupportedMedia
    case fileDecode
    case retryExhausted
    case unknown
}

public struct TranscriptionFailure: Error, Sendable, Equatable {
    public let kind: TranscriptionFailureKind
    public let message: String
    public let statusCode: Int?

    public init(
        kind: TranscriptionFailureKind,
        message: String,
        statusCode: Int? = nil
    ) {
        self.kind = kind
        self.message = message
        self.statusCode = statusCode
    }
}

public enum TranscriptionOutcome: Sendable, Equatable {
    case success
    case noSpeech
    case guarded(TranscriptionGuardReason)
    case timedOut
    case aborted
    case failed(TranscriptionFailure)

    public var telemetryValue: String {
        switch self {
        case .success: "success"
        case .noSpeech: "no_speech"
        case let .guarded(reason): "guarded_\(reason.rawValue)"
        case .timedOut: "timed_out"
        case .aborted: "aborted"
        case let .failed(failure): "failed_\(failure.kind.rawValue)"
        }
    }
}

/// Typed result for one realtime decode. Transcript text remains separate from
/// privacy-safe outcome metadata and must never be emitted in telemetry.
public struct TranscriptionStageDurations: Sendable, Equatable {
    public var languageDetectionSeconds: TimeInterval?
    public var decodeSeconds: TimeInterval?

    public init(languageDetectionSeconds: TimeInterval? = nil, decodeSeconds: TimeInterval? = nil) {
        self.languageDetectionSeconds = languageDetectionSeconds
        self.decodeSeconds = decodeSeconds
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var detectedLanguage: String
    public var outcome: TranscriptionOutcome
    public var backend: String?
    public var modelID: String?
    public var retryCount: Int
    public var durationSeconds: TimeInterval
    public var stageDurations: TranscriptionStageDurations?

    public init(
        text: String,
        detectedLanguage: String = "",
        outcome: TranscriptionOutcome? = nil,
        backend: String? = nil,
        modelID: String? = nil,
        retryCount: Int = 0,
        durationSeconds: TimeInterval = 0,
        stageDurations: TranscriptionStageDurations? = nil
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.outcome = outcome ?? (text.isEmpty ? .noSpeech : .success)
        self.backend = backend
        self.modelID = modelID
        self.retryCount = retryCount
        self.durationSeconds = durationSeconds
        self.stageDurations = stageDurations
    }

    public static let empty = TranscriptionResult(text: "", outcome: .noSpeech)

    public static func guarded(_ reason: TranscriptionGuardReason) -> TranscriptionResult {
        TranscriptionResult(text: "", outcome: .guarded(reason))
    }

    public static func failed(_ failure: TranscriptionFailure) -> TranscriptionResult {
        TranscriptionResult(text: "", outcome: .failed(failure))
    }
}

/// The speech-to-text backend contract. Local (WhisperKit / whisper.cpp) and
/// cloud (Gemini / OpenAI) engines all conform, so the pipeline is
/// engine-agnostic — the same duck-typing the Python `CloudSTTTranscriber` does
/// against `TranscriberProcessWrapper`, made an explicit protocol.
public protocol Transcribing: Sendable {
    /// Transcribe one chunk. Returns `.empty` on any skip/failure path rather
    /// than throwing, matching the Python `""` contract.
    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult

    /// One-time warm decode of silence to load/compile the model.
    func warmup(language: String?) async

    /// Validate and prepare a candidate before it becomes active. Unlike the
    /// best-effort keepalive API, preparation may fail and preserves the prior
    /// active service when it does.
    func prepare(language: String?) async throws

    /// Cheap keep-warm (throttled by the caller).
    func preWarm() async -> PrewarmResult

    /// Release resources / stop any child work.
    func stop() async

    /// Drop and re-acquire the model, releasing its memory. Called every N
    /// sessions and by the overdue watchdog.
    func reload() async

    /// Ask an in-flight decode to return early. Must be safe to call from any
    /// isolation while `transcribe` is running — that is the whole point.
    nonisolated func abortInFlight()

    /// Exact BPE token count from the engine's tokenizer, or nil when the engine
    /// has none (cloud backends) or no model is loaded yet. Used by
    /// `ChunkContextBuilder` to respect Whisper's 220-token prompt budget
    /// precisely instead of estimating.
    func tokenCount(_ text: String) async -> Int?

    /// Transcribe a complete media file through the richer, cancellable path.
    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult
}

public extension Transcribing {
    func warmup(language: String?) async {}
    func prepare(language: String?) async throws { await warmup(language: language) }
    func preWarm() async -> PrewarmResult { .skipped }
    func stop() async {}
    func reload() async { await stop() }
    nonisolated func abortInFlight() {}
    func tokenCount(_ text: String) async -> Int? { nil }
    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        FileTranscriptionResult.failed(
            .init(kind: .unavailable, message: "File transcription is unavailable")
        )
    }

    func transcribeFile(_ fileURL: URL) async throws -> String {
        let result = await transcribeFile(FileTranscriptionRequest(url: fileURL)) { _ in }
        switch result.status {
        case .success:
            return result.text
        case .noSpeech:
            return ""
        case .cancelled:
            throw CancellationError()
        case let .failed(failure):
            throw FileTranscriptionError(failure: failure)
        }
    }
}
