import Foundation

/// Placeholder transcriber for wiring up the record → chunk → HUD pipeline
/// before the real WhisperKit engine lands (task 2.4b, gated on the Phase 0
/// bake-off). It returns deterministic text derived from the request so the
/// end-to-end flow is observable and testable without a model.
public actor StubTranscriber: Transcribing {
    private var chunkIndex = 0
    private let makeText: @Sendable (Int, TranscriptionRequest) -> String

    /// - Parameter makeText: produces the returned text from the chunk index and
    ///   request. Defaults to a visible placeholder including audio length.
    public init(makeText: @escaping @Sendable (Int, TranscriptionRequest) -> String = { index, req in
        let seconds = Double(req.audio.count) / 16000.0
        return String(format: "[stub chunk %d · %.1fs%@]", index, seconds, req.isFinalChunk ? " · final" : "")
    }) {
        self.makeText = makeText
    }

    public func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        let index = chunkIndex
        chunkIndex += 1
        let lang = request.allowedLanguages.first ?? ""
        return TranscriptionResult(text: makeText(index, request), detectedLanguage: lang)
    }
}
