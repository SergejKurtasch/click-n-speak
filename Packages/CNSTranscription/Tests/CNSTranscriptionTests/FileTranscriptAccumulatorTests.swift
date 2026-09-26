import Foundation
import Testing
@testable import CNSTranscription

@Suite("File transcript accumulation")
struct FileTranscriptAccumulatorTests {
    @Test("Local cancellation preserves every completed segment and metadata")
    func localCancellationPreservesCompletedSegments() {
        var transcript = FileTranscriptAccumulator(
            backend: "local",
            modelID: "whisper-test"
        )
        transcript.append(text: "first segment.", detectedLanguage: "ru")
        transcript.append(text: "Second segment", detectedLanguage: "en")

        let result = transcript.result(status: .cancelled, segmentCount: 2)

        #expect(result.text == "first segment. Second segment")
        #expect(result.detectedLanguage == "en")
        #expect(result.backend == "local")
        #expect(result.modelID == "whisper-test")
        #expect(result.status == .cancelled)
        #expect(result.segmentCount == 2)
    }

    @Test("A failure preserves completed segments instead of becoming an empty result")
    func failurePreservesCompletedSegments() {
        var transcript = FileTranscriptAccumulator(
            backend: "openai",
            modelID: "cloud-test"
        )
        transcript.append(text: "usable partial", detectedLanguage: "en")
        let failure = TranscriptionFailure(kind: .network, message: "request failed")

        let result = transcript.result(status: .failed(failure), segmentCount: 1)

        #expect(result.text == "usable partial")
        #expect(result.status == .failed(failure))
        #expect(result.segmentCount == 1)
    }
}
