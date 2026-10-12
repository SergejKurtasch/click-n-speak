import Foundation
import CNSCore

/// Post-decode hallucination filtering ported 1:1 from the tail of
/// `WhisperTranscriber.transcribe`. Engine-independent: operates on decoded text
/// only. The language-mismatch retry (which needs a re-decode) stays in the
/// engine adapter.
///
/// Order:
/// 1. (non-final) suspicious-CJK drop
/// 2. hallucination phrase list (word-boundary, both final and non-final)
/// 3. prompt echo check (whole chunk or repeated prompt phrases)
/// 4. (non-final) single-word "you"/"the" drop
/// 5. collapse consecutive word repetition
/// 6. strip subword repetition
/// 7. strip prompt language hints at chunk boundaries (e.g. trailing "English language")
/// 8. strip leading/trailing dots, ellipses, spaces
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

    private static let excludedPrepositions: Set<String> = [
        "на", "с", "со", "про", "о", "об", "обо", "в", "во", "для", "по", "к", "ко", "от", "до", "без",
        "in", "into", "the", "a", "an", "of", "to", "from", "about", "with", "for", "on", "as"
    ]

    static let languageHintPhrases: [String] = LanguageConstants.langPrompts.values.map {
        $0.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    static let defaultContextPhrases: [String] = LanguageConstants.langDefaultContext.values.flatMap { ctx in
        ctx.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

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
    public func filter(_ text: String, isFinal: Bool, promptContext: String? = nil) -> String {
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

        // 3. Prompt echo check (whole chunk or repeated prompt phrases).
        if isWholeChunkPromptEcho(text, promptContext: promptContext) {
            return ""
        }

        // 4. Single-word "you"/"the" (non-final only).
        if !isFinal {
            let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if stripped == "you" || stripped == "the" {
                return ""
            }
        }

        // 5. Collapse consecutive word repetition.
        var result = collapseConsecutiveWordRepetition(text)

        // 6. Strip subword repetition (replace each run with a single unit).
        result = replaceSubwordRepetition(result)

        // 7. Strip prompt language hints at chunk boundaries (e.g. trailing "English language").
        result = stripPromptEchoBoundaries(result, promptContext: promptContext)

        // 8. Final cleanup: strip leading/trailing dots, ellipses, spaces.
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " .…"))
    }

    // MARK: - Helpers

    private func normalizeForEchoCheck(_ str: String) -> String {
        str.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet.punctuationCharacters))
    }

    private func knownPromptPhrases(promptContext: String?) -> Set<String> {
        var set = Set<String>()
        for h in Self.languageHintPhrases {
            let n = normalizeForEchoCheck(h)
            if !n.isEmpty { set.insert(n) }
        }
        for c in Self.defaultContextPhrases {
            let n = normalizeForEchoCheck(c)
            if !n.isEmpty { set.insert(n) }
        }
        if let promptContext, !promptContext.isEmpty {
            let parts = promptContext.components(separatedBy: CharacterSet(charactersIn: ".!?\n,"))
            for p in parts {
                let n = normalizeForEchoCheck(p)
                if !n.isEmpty { set.insert(n) }
            }
        }
        return set
    }

    func isWholeChunkPromptEcho(_ text: String, promptContext: String?) -> Bool {
        let normalized = normalizeForEchoCheck(text)
        guard !normalized.isEmpty else { return true }
        let known = knownPromptPhrases(promptContext: promptContext)
        if known.contains(normalized) { return true }

        let segments = text.components(separatedBy: CharacterSet(charactersIn: ",;\n.!?"))
            .map { normalizeForEchoCheck($0) }
            .filter { !$0.isEmpty }
        if !segments.isEmpty && segments.allSatisfy({ known.contains($0) }) {
            return true
        }
        return false
    }

    func stripPromptEchoBoundaries(_ text: String, promptContext: String?) -> String {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading language hint check
        for hint in Self.languageHintPhrases {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: hint) + "([.!?,:;—–-]*\\s*)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let nsRange = NSRange(current.startIndex..<current.endIndex, in: current)
                if let match = regex.firstMatch(in: current, options: [], range: nsRange),
                   let matchedRange = Range(match.range, in: current) {
                    let remaining = current[matchedRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remaining.isEmpty {
                        let matchString = String(current[matchedRange])
                        let hasPunctuation = matchString.contains(where: { ".!?,:;—–-".contains($0) })
                        let nextIsCapitalized = remaining.first?.isUppercase == true
                        if hasPunctuation || nextIsCapitalized {
                            current = remaining
                            break
                        }
                    }
                }
            }
        }

        // Trailing language hint check
        for hint in Self.languageHintPhrases {
            let pattern = "([\\s,!?:;—–-]+)" + NSRegularExpression.escapedPattern(for: hint) + "[.!?:;…]*$"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let nsRange = NSRange(current.startIndex..<current.endIndex, in: current)
                if let match = regex.firstMatch(in: current, options: [], range: nsRange),
                   let matchRange = Range(match.range, in: current) {
                    let prefix = current[..<matchRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prefix.isEmpty {
                        let lastWord = prefix.components(separatedBy: .whitespacesAndNewlines).last ?? ""
                        let normalizedLastWord = normalizeWord(lastWord)
                        if !Self.excludedPrepositions.contains(normalizedLastWord) {
                            current = prefix
                            break
                        }
                    }
                }
            }
        }
        return current
    }

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
