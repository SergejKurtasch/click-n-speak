import CNSCore
import Testing
@testable import CNSTranscription

@Suite("Prewarm outcome classification")
struct PrewarmOutcomeTests {
    @Test("Only completed silence decodes count as warmed")
    func completedSilenceDecode() {
        #expect(WhisperCppTranscriber.prewarmResult(for: .empty) == .warmed)
        #expect(WhisperCppTranscriber.prewarmResult(for: .init(text: "ready")) == .warmed)
    }

    @Test("Cancelled silence decode is skipped")
    func cancelledSilenceDecode() {
        let result = TranscriptionResult(text: "", outcome: .aborted)

        #expect(WhisperCppTranscriber.prewarmResult(for: result) == .skipped)
    }

    @Test("Timed out and failed silence decodes fail prewarm")
    func failedSilenceDecode() {
        let timedOut = TranscriptionResult(text: "", outcome: .timedOut)
        let failed = TranscriptionResult.failed(
            .init(kind: .decode, message: "decode failed")
        )

        #expect(WhisperCppTranscriber.prewarmResult(for: timedOut) == .failed)
        #expect(WhisperCppTranscriber.prewarmResult(for: failed) == .failed)
    }
}

@Suite("Language retry timing aggregation")
struct LanguageRetryAggregationTests {
    @Test("An empty retry retains the time spent on both decode attempts")
    func emptyRetryRetainsAllAttemptTiming() {
        let first = TranscriptionResult(
            text: "detected speech",
            detectedLanguage: "fr",
            retryCount: 2,
            durationSeconds: 1.25,
            stageDurations: .init(
                languageDetectionSeconds: 0.15,
                decodeSeconds: 1.10
            )
        )
        let retry = TranscriptionResult(
            text: "",
            detectedLanguage: "en",
            outcome: .noSpeech,
            durationSeconds: 0.75,
            stageDurations: .init(decodeSeconds: 0.75)
        )

        let combined = WhisperCppTranscriber.aggregateLanguageRetry(
            original: first,
            retry: retry
        )

        #expect(combined.text.isEmpty)
        #expect(combined.retryCount == 3)
        #expect(combined.durationSeconds == 2.0)
        #expect(combined.stageDurations?.languageDetectionSeconds == 0.15)
        #expect(combined.stageDurations?.decodeSeconds == 1.85)
    }

}
