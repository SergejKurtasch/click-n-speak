import Testing
import Foundation
import CNSCore
@testable import CNSTranscription

@Suite("ChunkContextBuilder (exact token counter)")
struct TokenAwareContextTests {
    let builder = ChunkContextBuilder()

    @Test("Async build matches sync build when the counter agrees")
    func matchesHeuristic() async {
        let heuristic = HeuristicTokenCounter()
        let sync = builder.build(
            instruction: "Inst. ", vocabPrompt: "Vocab.",
            transcribedParts: ["one", "two", "three"])
        let asyncResult = await builder.build(
            instruction: "Inst. ", vocabPrompt: "Vocab.",
            transcribedParts: ["one", "two", "three"],
            tokenCount: { heuristic.countTokens($0) })
        #expect(sync == asyncResult)
    }

    @Test("Falls back to the heuristic when the engine has no tokenizer")
    func nilFallback() async {
        let result = await builder.build(
            instruction: "Inst. ", vocabPrompt: "Vocab.",
            transcribedParts: ["one", "two"],
            tokenCount: { _ in nil })
        #expect(result == "Inst. Vocab. one two")
    }

    @Test("A stricter token counter drops recent chunks first, vocab survives")
    func stricterCounterTrimsRecent() async {
        // Every string costs 200 tokens: base fits the 220 budget, leaving 20 —
        // so no recent chunk can be added, but the vocab is never truncated.
        let result = await builder.build(
            instruction: "Inst. ", vocabPrompt: "MLX, PCA",
            transcribedParts: ["recent one", "recent two"],
            tokenCount: { _ in 200 })
        #expect(result == "Inst. MLX, PCA")
    }

    @Test("Budget that fits exactly one chunk keeps the most recent one")
    func keepsMostRecent() async {
        // base 100 → 120 tokens left; each chunk costs 100, so only one fits,
        // and it must be the most recent.
        let result = await builder.build(
            instruction: "Inst. ", vocabPrompt: "MLX, PCA",
            transcribedParts: ["recent one", "recent two"],
            tokenCount: { _ in 100 })
        #expect(result == "Inst. MLX, PCA recent two")
    }

    @Test("Token counter results are cached (each distinct string counted once)")
    func caching() async {
        let calls = Counter()
        _ = await builder.build(
            instruction: "I. ", vocabPrompt: "V.",
            transcribedParts: ["a", "b", "c"],
            tokenCount: { _ in await calls.bump(); return 1 })
        // base + 3 chunk fragments = 4 distinct strings.
        let n = await calls.value
        #expect(n == 4)
    }

    actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}

@Suite("Transcribing defaults")
struct TranscribingDefaultTests {
    @Test("Engines without a tokenizer return nil")
    func stubHasNoTokenizer() async {
        let stub = StubTranscriber()
        #expect(await stub.tokenCount("hello") == nil)
    }

    @Test("GuardedTranscriber forwards tokenCount to the wrapped engine")
    func guardedForwards() async {
        let guarded = GuardedTranscriber(wrapping: FakeCountingTranscriber())
        #expect(await guarded.tokenCount("abc") == 42)
    }

    struct FakeCountingTranscriber: Transcribing {
        func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult { .empty }
        func tokenCount(_ text: String) async -> Int? { 42 }
    }
}
