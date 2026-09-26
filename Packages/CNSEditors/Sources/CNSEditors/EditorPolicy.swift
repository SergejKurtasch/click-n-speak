import CNSCore
import Foundation

public enum EditorPolicy {
    public static let realtimeWarmTimeout: TimeInterval = 8
    public static let realtimeColdTimeout: TimeInterval = 25
    public static let coldIdleThreshold: TimeInterval = 300
    public static let fileGateTimeout: TimeInterval = 10
    public static let fileOperationTimeout: TimeInterval = 300
    public static let localContextTokens = 32_768
    public static let localSystemPromptTokens = 400
    public static let localMaximumFileChunkCharacters = 39_960

    private static let realtimeFillerWords: [String: [String]] = [
        "ru": ["э", "эм", "ну", "типа", "короче", "как бы", "значит", "вот", "это самое"],
        "uk": ["е", "ем", "ну", "типу", "значить", "от", "це саме"],
        "en": ["uh", "um", "like", "you know", "so", "right", "basically", "I mean", "kind of", "sort of"],
        "de": ["äh", "ähm", "halt", "irgendwie", "sozusagen", "quasi", "also"],
        "fr": ["euh", "ben", "genre", "bref", "du coup", "voilà"],
        "es": ["eh", "este", "o sea", "bueno", "pues", "osea"],
        "it": ["eh", "allora", "cioè", "praticamente", "tipo", "ecco"],
        "pt": ["é", "assim", "tipo", "né", "então", "sabe"],
        "pl": ["ee", "yyy", "no", "właśnie", "znaczy", "jakby"],
        "nl": ["eh", "uhm", "zeg maar", "eigenlijk", "nou"],
        "tr": ["yani", "işte", "şey", "falan"],
    ]

    public static func realtimeMaximumOutputTokens(for text: String) -> Int {
        min(1_024, max(64, Int(Double(text.count) * 0.8)))
    }

    public static func fileMaximumOutputTokens(for text: String) -> Int {
        max(256, Int(Double(text.count) / 2.5) + 500)
    }

    public static func splitAtSentenceBoundaries(
        _ text: String,
        maximumCharacters: Int = localMaximumFileChunkCharacters
    ) -> [String] {
        guard maximumCharacters > 0, text.count > maximumCharacters else { return [text] }
        var chunks: [String] = []
        var remaining = text
        let separators = [". ", ".\n", "! ", "!\n", "? ", "?\n"]

        while remaining.count > maximumCharacters {
            let limit = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
            let prefix = remaining[..<limit]
            var best: String.Index?
            for separator in separators {
                if let range = prefix.range(of: separator, options: .backwards) {
                    let boundary = remaining.index(range.lowerBound, offsetBy: 1)
                    if best == nil || boundary > best! { best = boundary }
                }
            }
            let boundary = best ?? remaining.index(before: limit)
            let part = remaining[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { chunks.append(part) }
            remaining = String(remaining[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    static func validatedOutput(_ output: String, original: String, multiplier: Double) -> RefineResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == original.trimmingCharacters(in: .whitespacesAndNewlines) {
            return RefineResult(text: original, status: .unchanged)
        }
        let cleaned = normalizeSentenceEnding(trimmed)
        guard !cleaned.isEmpty, cleaned.count <= max(original.count + 32, Int(Double(original.count) * multiplier)) else {
            return RefineResult(text: original, status: .error)
        }
        return RefineResult(text: cleaned, status: .ok)
    }

    /// Validates the local realtime editor's conservative word-preservation
    /// contract. It permits punctuation, capitalization, listed fillers, and
    /// immediate repeated words, but rejects a rewrite or invented content.
    static func validatedRealtimeOutput(
        _ output: String,
        original: String,
        languages: [String]?,
        multiplier: Double
    ) -> RefineResult {
        let result = validatedOutput(output, original: original, multiplier: multiplier)
        guard result.status == .ok else { return result }
        guard preservesRealtimeWords(
            original: original,
            candidate: result.text,
            languages: languages
        ) else {
            return RefineResult(text: original, status: .error)
        }
        return result
    }

    static func fillerPhrases(languages: [String]?) -> [String] {
        guard let languages, !languages.isEmpty else { return [] }
        return languages.flatMap { realtimeFillerWords[$0] ?? [] }
    }

    /// The editor's explicit contract is to return punctuated prose. Small
    /// local models occasionally preserve every word but omit only the final
    /// stop, so complete that mechanical edit without attempting to infer a
    /// question or otherwise rewriting model output.
    private static func normalizeSentenceEnding(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        return text + "."
    }

    private static func preservesRealtimeWords(
        original: String,
        candidate: String,
        languages: [String]?
    ) -> Bool {
        let source = normalizedWords(original)
        let result = normalizedWords(candidate)
        let fillerPhrases = (languages ?? realtimeFillerWords.keys.sorted())
            .flatMap { realtimeFillerWords[$0] ?? [] }
            .map(normalizedWords)
            .filter { !$0.isEmpty }
        var reachable = Array(
            repeating: Array(repeating: false, count: result.count + 1),
            count: source.count + 1
        )
        reachable[0][0] = true

        for sourceIndex in 0 ... source.count {
            for resultIndex in 0 ... result.count where reachable[sourceIndex][resultIndex] {
                if sourceIndex < source.count,
                   resultIndex < result.count,
                   source[sourceIndex] == result[resultIndex] {
                    reachable[sourceIndex + 1][resultIndex + 1] = true
                }
                if sourceIndex + 1 < source.count,
                   source[sourceIndex] == source[sourceIndex + 1] {
                    reachable[sourceIndex + 1][resultIndex] = true
                }
                for phrase in fillerPhrases where phraseMatches(phrase, source: source, at: sourceIndex) {
                    reachable[sourceIndex + phrase.count][resultIndex] = true
                }
            }
        }
        return reachable[source.count][result.count]
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
    }

    private static func phraseMatches(_ phrase: [String], source: [String], at index: Int) -> Bool {
        guard index + phrase.count <= source.count else { return false }
        return source[index ..< index + phrase.count].elementsEqual(phrase)
    }
}
