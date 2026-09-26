import Foundation

/// Words never worth adding to the dictionary on their own — ported verbatim
/// from `TERM_STOPLIST` in `log_analyzer.py`.
public enum TermStoplist {
    public static let words: Set<String> = [
        "http", "https", "www", "com", "org", "net", "edu", "gov",
        "the", "and", "for", "are", "but", "not", "you", "all",
        "can", "had", "her", "was", "one", "our", "out", "day",
        "get", "has", "him", "his", "how", "man", "new", "now",
        "old", "see", "two", "way", "who", "its", "let", "put",
        "say", "she", "too", "use",
        // Common prepositions / particles missing from the original list
        "to", "in", "on", "of", "at", "be", "do", "go", "up",
        "as", "an", "by", "if", "or", "so", "we", "my", "me",
        "no", "is", "it", "he", "us", "ok", "vs", "hi",
    ]
}

/// Picking a dictionary term out of the popup's text.
///
/// Ported from `_word_at_offset` / `_is_valid_term` / `_iter_term_spans` in
/// `preview_panel.py`. Token boundaries keep `+ # . _ -` inside a word so
/// `C++`, `node.js` and `v2.1` survive as single terms.
public enum TermParsing {
    public static let maxTermWords = 4
    public static let maxTermChars = 60

    public static func isTermStartCharacter(_ char: Character) -> Bool {
        char.isLetter
    }

    public static func isTermCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || "+#._-".contains(char)
    }

    /// Term-like token spans as character index ranges.
    public static func termSpans(_ characters: [Character]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var i = 0
        while i < characters.count {
            guard isTermStartCharacter(characters[i]) else {
                i += 1
                continue
            }
            let start = i
            i += 1
            while i < characters.count, isTermCharacter(characters[i]) {
                i += 1
            }
            spans.append(start..<i)
        }
        return spans
    }

    /// The token containing the caret, or the nearest one when the caret sits in
    /// whitespace. `utf16Offset` is what `NSTextView.selectedRange` reports.
    public static func wordAtOffset(_ text: String, utf16Offset: Int) -> String {
        guard !text.isEmpty else { return "" }
        let characters = Array(text)
        let offset = characterOffset(forUTF16: utf16Offset, in: text)

        var best = ""
        var bestDistance: Int?
        for span in termSpans(characters) {
            if span.contains(offset) { return String(characters[span]) }
            if offset == span.upperBound, !span.isEmpty { return String(characters[span]) }
            let distance = offset < span.lowerBound ? span.lowerBound - offset : offset - span.upperBound
            if bestDistance == nil || distance < bestDistance! {
                bestDistance = distance
                best = String(characters[span])
            }
        }
        return best
    }

    /// Whether `word` may go into `user_terms` — the same gate the popup applies
    /// before calling back into the dictionary.
    public static func isValidTerm(_ word: String) -> Bool {
        let words = word.split(whereSeparator: \.isWhitespace).map(String.init)
        let candidate = words.joined(separator: " ")
        guard candidate.count >= 2, candidate.count <= maxTermChars else { return false }
        guard !candidate.allSatisfy(\.isNumber) else { return false }
        guard candidate.contains(where: \.isLetter) else { return false }
        guard words.count <= maxTermWords else { return false }
        for w in words {
            guard let first = w.first, isTermStartCharacter(first) else { return false }
            guard w.allSatisfy(isTermCharacter) else { return false }
        }
        // Multi-word phrases are deliberate, so the stoplist applies to single words only.
        if words.count == 1, TermStoplist.words.contains(candidate.lowercased()) { return false }
        return true
    }

    private static func characterOffset(forUTF16 offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.utf16.count))
        let index = String.Index(utf16Offset: clamped, in: text)
        return text.distance(from: text.startIndex, to: index)
    }
}
