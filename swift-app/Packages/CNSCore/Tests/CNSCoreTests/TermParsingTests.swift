import Testing
@testable import CNSCore

/// Expectations captured from the real `preview_panel._word_at_offset` /
/// `_is_valid_term` (see CONVENTIONS.md: the Python code is the spec).
@Suite("TermParsing")
struct TermParsingTests {
    @Test("Word at caret offset", arguments: [
        ("hello world", 0, "hello"),
        ("hello world", 5, "hello"),   // caret at the end of a token still picks it
        ("hello world", 6, "world"),
        ("hello world", 11, "world"),
        ("  node.js rules", 0, "node.js"),  // caret in whitespace → nearest token
        ("C++ и Swift", 2, "C++"),
        ("привет мир", 8, "мир"),
        ("", 3, ""),
        ("a  b", 2, "a"),              // equidistant → the earlier token wins
    ])
    func wordAtOffset(_ text: String, _ offset: Int, _ expected: String) {
        #expect(TermParsing.wordAtOffset(text, utf16Offset: offset) == expected)
    }

    @Test("Offsets outside the text are clamped")
    func clampsOffsets() {
        #expect(TermParsing.wordAtOffset("hello", utf16Offset: 999) == "hello")
        #expect(TermParsing.wordAtOffset("hello", utf16Offset: -5) == "hello")
    }

    @Test("Term validity", arguments: [
        ("a", false),                     // too short
        ("ab", true),
        ("the", false),                   // stoplist
        ("The", false),                   // stoplist is case-insensitive
        ("123", false),                   // digits only
        ("C++", true),
        ("node.js", true),
        ("v2.1", true),
        ("кот", true),
        ("привет мир", true),
        ("hi there", true),               // stoplist does not apply to phrases
        ("one two three four five", false),  // more than 4 words
        ("-dash", false),                 // must start with a letter
        ("  spaced  term  ", true),
    ])
    func isValidTerm(_ word: String, _ expected: Bool) {
        #expect(TermParsing.isValidTerm(word) == expected)
    }

    @Test("A term longer than 60 characters is rejected")
    func rejectsOverlongTerms() {
        #expect(TermParsing.isValidTerm(String(repeating: "a", count: 60)) == true)
        #expect(TermParsing.isValidTerm(String(repeating: "a", count: 61)) == false)
    }
}
