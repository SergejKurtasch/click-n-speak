import Foundation

/// Term canonicalisation contract ported 1:1 from `utils.py`
/// (`canonicalize_term` / `canonical_term_key`). Only boundary punctuation and
/// whitespace are stripped; inner symbols like `+ # . _ -` are preserved
/// (C++, node.js, v2.1), and semantic leading prefixes `.NET` / `@mention` are kept.
public enum TermCanonicalizer {
    /// ASCII punctuation minus the inner-meaningful `+#_-`, plus a set of
    /// unicode boundary punctuation. Mirrors `_TERM_BOUNDARY_PUNCT`.
    private static let boundaryPunct: Set<Character> = {
        let asciiPunct = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        var set = Set(asciiPunct)
        for c in "+#_-" { set.remove(c) }
        for c in "«»“”„‟‘’‚‛…—–·，。！？、：；（）【】《》「」『』" { set.insert(c) }
        return set
    }()

    private static let semanticLeadingPunct: Set<Character> = [".", "@"]

    /// Collapse runs of whitespace into single spaces and trim, matching
    /// Python's `" ".join(str(term).split())`.
    private static func collapseWhitespace(_ term: String) -> String {
        term.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0B}" || $0 == "\u{0C}" })
            .joined(separator: " ")
    }

    private static func isSemanticLeadingPunct(_ chars: [Character], _ idx: Int) -> Bool {
        guard idx >= 0 && idx < chars.count else { return false }
        let ch = chars[idx]
        guard semanticLeadingPunct.contains(ch) else { return false }
        guard idx + 1 < chars.count else { return false }
        return chars[idx + 1].isLetter || chars[idx + 1].isNumber
    }

    /// Normalize a term for display/storage without touching inner symbols
    /// (`canonicalize_term`).
    public static func canonicalize(_ term: String) -> String {
        let text = collapseWhitespace(term)
        if text.isEmpty { return "" }
        let chars = Array(text)
        var start = 0
        var end = chars.count
        while start < end && boundaryPunct.contains(chars[start]) {
            if isSemanticLeadingPunct(chars, start) { break }
            start += 1
        }
        while end > start && boundaryPunct.contains(chars[end - 1]) {
            end -= 1
        }
        return String(chars[start..<end])
    }

    /// Lowercase identity key after boundary normalization (`canonical_term_key`).
    public static func canonicalKey(_ term: String) -> String {
        canonicalize(term).lowercased()
    }
}
