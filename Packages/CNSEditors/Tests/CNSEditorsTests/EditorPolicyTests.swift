import CNSCore
import Testing
@testable import CNSEditors

@Suite("Editor policy")
struct EditorPolicyTests {
    @Test("Every dataset-compatible status remains represented")
    func everyStatus() {
        #expect(Set(RefineStatus.allCases.map(\.rawValue)) == Set([
            "ok", "unchanged", "timeout", "skipped", "error", "disabled", "memory_pressure",
        ]))
    }

    @Test("Long file text splits at sentence boundaries and preserves order")
    func sentenceSplitting() {
        let text = "First complete sentence. Second complete sentence! Third complete sentence? Final tail."
        let chunks = EditorPolicy.splitAtSentenceBoundaries(text, maximumCharacters: 34)
        #expect(chunks.count > 1)
        #expect(chunks.first == "First complete sentence.")
        #expect(chunks.joined(separator: " ") == text)
        #expect(chunks.allSatisfy { $0.count <= 34 })
    }

    @Test("Validation completes a missing final stop without replacing existing punctuation")
    func sentenceEndingNormalization() {
        let source = "This transcript contains enough words for a realistic editor request"
        #expect(EditorPolicy.validatedOutput(source, original: source, multiplier: 2.5) == RefineResult(
            text: source,
            status: .unchanged
        ))
        #expect(EditorPolicy.validatedOutput(source.lowercased(), original: source, multiplier: 2.5) == RefineResult(
            text: source.lowercased() + ".",
            status: .ok
        ))
        #expect(EditorPolicy.validatedOutput(source + "?", original: source, multiplier: 2.5).text == source + "?")
    }
}
