import Foundation

/// Post-decode hallucination filtering ported 1:1 from the tail of
/// `WhisperTranscriber.transcribe`. Engine-independent: operates on decoded text
/// only. The language-mismatch retry (which needs a re-decode) stays in the
/// engine adapter.
///
/// Order matches Python exactly:
/// 1. (non-final) suspicious-CJK drop
/// 2. hallucination phrase list (word-boundary, both final and non-final)
/// 3. (non-final) single-word "you"/"the" drop
/// 4. collapse consecutive word repetition
/// 5. strip subword repetition
/// 6. strip leading/trailing dots, ellipses, spaces
public struct HallucinationFilter: Sendable {
    /// Whisper hallucination phrases matched as whole words/phrases
    /// (`_hallucination_phrases`).
    static let phrases: [String] = [
        "thank you", "thanks for watching", "благодарю", "подпишитесь",
        "продолжение следует", "subtitles by", "amara.org", "the amara.org community",
        "captioning by", "translated by", "don't forget to", "you for watching",
        "a s s u b t i t l e s", "by the amara", "y cómo va a funcionar", "subtitles",
        "субтитры подогнал", "подогнал симон", "десерт", "субтитры подготовил",
        "субтитры сделал", "субтитры создавал", "субтитры создал", "субтитры",
        "редактор субтитров", "перевод на русский",
    ]

    private let phraseRegex: NSRegularExpression

    public init() {
        let pattern = HallucinationFilter.phrases
            .map { "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b" }
            .joined(separator: "|")
        do {
            phraseRegex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Static hallucination phrase regex is invalid: \(error)")
        }
    }

    /// Filter decoded `text`. Returns "" when the chunk is dropped as a
    /// hallucination, otherwise the cleaned text.
    public func filter(_ text: String, isFinal: Bool) -> String {
        let lower = text.lowercased()

        // 1. Suspicious CJK (non-final, aggressive).
        if !isFinal {
            let asian = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
            if asian > 2 && asian > text.count / 3 {
                return ""
            }
        }

        // 2. Phrase list (both final and non-final).
        if firstMatch(phraseRegex, in: lower) != nil {
            return ""
        }

        // 3. Single-word "you"/"the" (non-final only).
        if !isFinal {
            let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if stripped == "you" || stripped == "the" {
                return ""
            }
        }

        // 4. Collapse consecutive word repetition.
        var result = collapseConsecutiveWordRepetition(text)

        // 5. Strip subword repetition (replace each run with a single unit).
        result = replaceSubwordRepetition(result)

        // 6. Final cleanup: strip leading/trailing dots, ellipses, spaces.
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " .…"))
    }

    // MARK: - Helpers

    /// `_collapse_consecutive_word_repetition`.
    func collapseConsecutiveWordRepetition(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return text }
        var out = [first]
        var prev = normalizeWord(first)
        for w in words.dropFirst() {
            let curr = normalizeWord(w)
            if !curr.isEmpty && curr == prev { continue }
            out.append(w)
            prev = curr
        }
        return out.joined(separator: " ")
    }

    /// `_normalize_word`: lowercase and strip leading/trailing punctuation.
    func normalizeWord(_ w: String) -> String {
        let lower = w.lowercased()
        let wordNormalizeRegex = /^[\W_]+|[\W_]+$/
        return lower.replacing(wordNormalizeRegex, with: "")
    }

    private func replaceSubwordRepetition(_ text: String) -> String {
        let subwordRepeatRegex = /(.{2,8}?)\1{5,}/
        return text.replacing(subwordRepeatRegex, with: { match in
            String(match.output.1)
        })
    }

    private func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
