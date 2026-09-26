import Testing
@testable import CNSTranscription

@Suite("StubTranscriber")
struct StubTranscriberTests {
    @Test("Language-specific prompts default empty and preserve supplied values")
    func languageSpecificPrompts() {
        #expect(TranscriptionRequest(audio: []).initialPromptsByLanguage.isEmpty)

        let request = TranscriptionRequest(
            audio: [],
            initialPrompt: "fallback",
            initialPromptsByLanguage: ["en": "English terms", "ru": "Русские термины"]
        )

        #expect(request.initialPrompt == "fallback")
        #expect(request.initialPromptsByLanguage == [
            "en": "English terms",
            "ru": "Русские термины",
        ])
    }

    @Test("Increments chunk index and reports audio length")
    func indexing() async {
        let stub = StubTranscriber()
        let r0 = await stub.transcribe(TranscriptionRequest(audio: [Float](repeating: 0, count: 16000)))
        let r1 = await stub.transcribe(TranscriptionRequest(audio: [Float](repeating: 0, count: 8000), isFinalChunk: true))
        #expect(r0.text == "[stub chunk 0 · 1.0s]")
        #expect(r1.text == "[stub chunk 1 · 0.5s · final]")
    }

    @Test("Reports first allowed language as detected")
    func language() async {
        let stub = StubTranscriber()
        let r = await stub.transcribe(TranscriptionRequest(audio: [], allowedLanguages: ["ru", "en"]))
        #expect(r.detectedLanguage == "ru")
    }

    @Test("Custom text closure")
    func customText() async {
        let stub = StubTranscriber(makeText: { _, _ in "hello" })
        let r = await stub.transcribe(TranscriptionRequest(audio: []))
        #expect(r.text == "hello")
    }
}
