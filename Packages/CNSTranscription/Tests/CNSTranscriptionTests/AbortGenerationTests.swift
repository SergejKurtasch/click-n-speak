import Testing
@testable import CNSTranscription

@Suite("Whisper abort generations")
struct AbortGenerationTests {
    @Test("An abort never leaks into the next decode generation")
    func abortIsGenerationScoped() {
        let flag = AbortFlag()
        let first = flag.beginGeneration()

        #expect(first.isAborted == false)
        flag.abortActiveGeneration()
        #expect(first.isAborted == true)
        flag.endGeneration(first.generation)

        // A late abort between decodes has no active generation to mark.
        flag.abortActiveGeneration()
        let second = flag.beginGeneration()
        #expect(second.generation > first.generation)
        #expect(second.isAborted == false)
    }

    @Test("Concurrent polling observes a synchronized abort")
    func concurrentPolling() async {
        let flag = AbortFlag()
        let token = flag.beginGeneration()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1_000 { _ = token.isAborted }
                }
            }
            flag.abortActiveGeneration()
        }

        #expect(token.isAborted == true)
    }
}
