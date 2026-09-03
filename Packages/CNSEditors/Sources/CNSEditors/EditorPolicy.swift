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

    /// The editor's explicit contract is to return punctuated prose. Small
    /// local models occasionally preserve every word but omit only the final
    /// stop, so complete that mechanical edit without attempting to infer a
    /// question or otherwise rewriting model output.
    private static func normalizeSentenceEnding(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        return text + "."
    }
}
