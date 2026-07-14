import Foundation

/// One transcription request for an audio chunk. Fields mirror the parameters of
/// `TranscriberProcessWrapper.transcribe` in `transcriber.py`.
public struct TranscriptionRequest: Sendable {
    /// 16 kHz mono float32 samples.
    public var audio: [Float]
    /// Whisper `initial_prompt` (dictionary + recent context), or nil.
    public var initialPrompt: String?
    /// Allowed language codes; empty means auto-detect (no hint).
    public var allowedLanguages: [String]
    /// Whether to condition on previously decoded text.
    public var conditionOnPreviousText: Bool
    /// True for the last chunk of a session (relaxes short-chunk guards).
    public var isFinalChunk: Bool

    public init(
        audio: [Float],
        initialPrompt: String? = nil,
        allowedLanguages: [String] = [],
        conditionOnPreviousText: Bool = true,
        isFinalChunk: Bool = false
    ) {
        self.audio = audio
        self.initialPrompt = initialPrompt
        self.allowedLanguages = allowedLanguages
        self.conditionOnPreviousText = conditionOnPreviousText
        self.isFinalChunk = isFinalChunk
    }
}

/// Result of a transcription. Empty `text` signals a skipped/failed decode
/// (guards, timeout, hallucination filter), matching the Python contract where
/// `transcribe` returns `""` on those paths.
public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var detectedLanguage: String

    public init(text: String, detectedLanguage: String = "") {
        self.text = text
        self.detectedLanguage = detectedLanguage
    }

    public static let empty = TranscriptionResult(text: "")
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

    /// Cheap keep-warm (throttled by the caller).
    func preWarm() async

    /// Release resources / stop any child work.
    func stop() async
}

public extension Transcribing {
    func warmup(language: String?) async {}
    func preWarm() async {}
    func stop() async {}
}
