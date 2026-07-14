import Testing
@testable import CNSTranscription

@Suite("GuardedTranscriber")
struct GuardedTranscriberTests {
    @Test("Tiny final chunk skipped before the engine runs")
    func skipsTinyFinal() async {
        let guarded = GuardedTranscriber(wrapping: StubTranscriber(makeText: { _, _ in "should not appear" }))
        let r = await guarded.transcribe(TranscriptionRequest(
            audio: [Float](repeating: 0.1, count: 8000), isFinalChunk: true))
        #expect(r == .empty)
    }

    @Test("Hallucinated engine output is filtered to empty")
    func filtersHallucination() async {
        let guarded = GuardedTranscriber(wrapping: StubTranscriber(makeText: { _, _ in "Thank you" }))
        let r = await guarded.transcribe(TranscriptionRequest(
            audio: [Float](repeating: 0.1, count: 48000)))
        #expect(r == .empty)
    }

    @Test("Clean output passes through with language preserved")
    func passesClean() async {
        let guarded = GuardedTranscriber(wrapping: StubTranscriber(makeText: { _, _ in "привет мир" }))
        let r = await guarded.transcribe(TranscriptionRequest(
            audio: [Float](repeating: 0.1, count: 48000), allowedLanguages: ["ru"]))
        #expect(r.text == "привет мир")
        #expect(r.detectedLanguage == "ru")
    }
}
