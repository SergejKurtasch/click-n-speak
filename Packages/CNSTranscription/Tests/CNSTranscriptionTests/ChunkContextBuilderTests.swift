import Testing
@testable import CNSTranscription

@Suite("ChunkContextBuilder")
struct ChunkContextBuilderTests {
    let builder = ChunkContextBuilder() // heuristic token counter

    @Test("All recent chunks fit under budget (matches Python)")
    func allChunksFit() {
        let r = builder.build(
            instruction: "Add punctuation. ",
            vocabPrompt: "Русский язык. MLX, PCA",
            transcribedParts: ["привет как дела", "всё хорошо спасибо", "что нового у тебя"]
        )
        #expect(r == "Add punctuation. Русский язык. MLX, PCA привет как дела всё хорошо спасибо что нового у тебя")
    }

    @Test("No recent parts returns base only")
    func noParts() {
        let r = builder.build(instruction: "Inst. ", vocabPrompt: "Vocab.", transcribedParts: [])
        #expect(r == "Inst. Vocab.")
    }

    @Test("Recent chunks exceeding the 50% char budget are dropped")
    func oversizedChunksDropped() {
        let r = builder.build(
            instruction: "Inst. ",
            vocabPrompt: "Vocab.",
            transcribedParts: [String(repeating: "a", count: 400), String(repeating: "b", count: 400)]
        )
        // available_chars = min(687, 350) = 350; each 400-char chunk exceeds it.
        #expect(r == "Inst. Vocab.")
    }

    @Test("Only at most 3 most-recent chunks are considered, in order")
    func windowAndOrder() {
        let base = String(repeating: "X", count: 250) + String(repeating: "Y", count: 250)
        let r = builder.build(
            instruction: String(repeating: "X", count: 250),
            vocabPrompt: String(repeating: "Y", count: 250),
            transcribedParts: ["recent one", "recent two"]
        )
        #expect(r == base + " recent one recent two")
        #expect(r.unicodeScalars.count == 522)
    }

    @Test("Fourth-oldest chunk is excluded by the 3-chunk window")
    func maxThreeChunks() {
        let r = builder.build(
            instruction: "I. ",
            vocabPrompt: "V.",
            transcribedParts: ["one", "two", "three", "four"]
        )
        // Only the last three ("two three four") are eligible; "one" never appears.
        #expect(r.contains("two three four"))
        #expect(!r.contains("one"))
    }
}
