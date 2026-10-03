import Foundation
import Testing
@testable import CNSTranscription

private actor UncooperativeTranscriber: Transcribing {
    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                continuation.resume(returning: TranscriptionResult(text: "late"))
            }
        }
    }
}

@Suite("GuardedTranscriber")
struct GuardedTranscriberTests {
    @Test("Tiny final chunk skipped before the engine runs")
    func skipsTinyFinal() async {
        let guarded = GuardedTranscriber(wrapping: StubTranscriber(makeText: { _, _ in "should not appear" }))
        let r = await guarded.transcribe(TranscriptionRequest(
            audio: [Float](repeating: 0.1, count: 8000), isFinalChunk: true))
        #expect(r.outcome == .guarded(.tinyFinalChunk))
    }

    @Test("Hallucinated engine output is filtered to empty")
    func filtersHallucination() async {
        let guarded = GuardedTranscriber(wrapping: StubTranscriber(makeText: { _, _ in "Thank you" }))
        let r = await guarded.transcribe(TranscriptionRequest(
            audio: [Float](repeating: 0.1, count: 48000)))
        #expect(r.outcome == .guarded(.hallucination))
    }

    @Test("Clean output passes through with language preserved")
    func passesClean() async {
        let guarded = GuardedTranscriber(wrapping: StubTranscriber(makeText: { _, _ in "привет мир" }))
        let r = await guarded.transcribe(TranscriptionRequest(
            audio: [Float](repeating: 0.1, count: 48000), allowedLanguages: ["ru"]))
        #expect(r.text == "привет мир")
        #expect(r.detectedLanguage == "ru")
    }

    @Test("Decode deadline returns without waiting for an uncooperative engine")
    func deadlineDoesNotJoinEngine() async {
        let guarded = GuardedTranscriber(wrapping: UncooperativeTranscriber())
        let started = Date()
        let result = await guarded.transcribe(TranscriptionRequest(
            audio: [Float](repeating: 0.1, count: 48_000),
            decodeTimeout: 0.02
        ))

        #expect(result.outcome == .timedOut)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}
