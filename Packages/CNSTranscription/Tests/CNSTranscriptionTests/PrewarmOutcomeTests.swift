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
