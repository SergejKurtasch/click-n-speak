import Foundation

/// Wraps any `Transcribing` engine with the engine-independent pre-decode audio
/// guards and post-decode hallucination filtering from `transcriber.py`. Keeps
/// those concerns out of each engine adapter so local and cloud backends share
/// identical filtering behaviour.
public struct GuardedTranscriber: Transcribing {
    private let inner: any Transcribing
    private let filter: HallucinationFilter

    public init(wrapping inner: any Transcribing, filter: HallucinationFilter = HallucinationFilter()) {
        self.inner = inner
        self.filter = filter
    }

    public func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        // Pre-decode guards: skip silence / tiny chunks before hitting the engine.
        if AudioGuards.skipReason(
            sampleCount: request.audio.count, samples: request.audio, isFinal: request.isFinalChunk
        ) != nil {
            return .empty
        }

        let result = await inner.transcribe(request)
        guard !result.text.isEmpty else { return .empty }

        let cleaned = filter.filter(result.text, isFinal: request.isFinalChunk)
        guard !cleaned.isEmpty else { return .empty }
        return TranscriptionResult(text: cleaned, detectedLanguage: result.detectedLanguage)
    }

    public func warmup(language: String?) async { await inner.warmup(language: language) }
    public func preWarm() async { await inner.preWarm() }
    public func stop() async { await inner.stop() }
    public func reload() async { await inner.reload() }
    public nonisolated func abortInFlight() { inner.abortInFlight() }
    public func tokenCount(_ text: String) async -> Int? { await inner.tokenCount(text) }
}
