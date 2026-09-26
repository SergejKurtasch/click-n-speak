import Testing
@testable import CNSSession

/// Expected values taken from the real `app._join_chunks`.
@Suite("ChunkJoiner")
struct ChunkJoinerTests {
    @Test("Joined chunks match the Python output", arguments: [
        ([], ""),
        (["одна"], "одна"),
        // A full stop before a lowercase continuation is Whisper punctuating a
        // chunk boundary, not a sentence end.
        (["Первая часть.", "вторая часть"], "Первая часть вторая часть"),
        (["Первая часть.", "Вторая часть"], "Первая часть. Вторая часть"),
        (["Вопрос?", "ответ"], "Вопрос ответ"),
        (["a", "b", "c"], "a b c"),
        (["  раз  ", "два  "], "раз   два"),
    ] as [([String], String)])
    func joins(_ parts: [String], _ expected: String) {
        #expect(ChunkJoiner.join(parts) == expected)
    }
}
