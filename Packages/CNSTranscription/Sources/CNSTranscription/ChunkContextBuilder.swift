import Foundation
import CNSCore

/// Builds the per-chunk `initial_prompt` sliding-window context, ported 1:1 from
/// `_build_chunk_context` in `app.py`.
///
/// Guarantees:
/// - token count ≤ `tokenLimit` (BPE, 220)
/// - character length ≤ `charBudget` (700)
/// - `vocabPrompt` preserved whole; recent chunks trimmed first
/// - recent text ≤ 50% of the char budget and at most 3 recent chunks
///
/// Token counting uses the injected `TokenCounting`; Phase 2 passes the
/// heuristic counter, Phase 2b swaps in the WhisperKit tokenizer for exactness.
public struct ChunkContextBuilder: Sendable {
    public static let tokenLimit = 220
    public static let charBudget = 700
    static let recentCharsRatio = 0.5
    static let maxRecentChunks = 3

    private let tokenCounter: TokenCounting
    private let charBudget: Int
    private let tokenLimit: Int

    public init(
        tokenCounter: TokenCounting = HeuristicTokenCounter(),
        charBudget: Int = ChunkContextBuilder.charBudget,
        tokenLimit: Int = ChunkContextBuilder.tokenLimit
    ) {
        self.tokenCounter = tokenCounter
        self.charBudget = charBudget
        self.tokenLimit = tokenLimit
    }

    /// Python `len(str)` counts Unicode code points; match that.
    private func length(_ s: String) -> Int { s.unicodeScalars.count }

    public func build(instruction: String, vocabPrompt: String, transcribedParts: [String]) -> String {
        let base = instruction + vocabPrompt
        let baseTokens = tokenCounter.countTokens(base)
        // (base-over-limit is only logged in Python; recent_text is still skipped
        // naturally because availableTokens becomes 0.)

        let availableChars = min(
            max(0, charBudget - length(base) - 1),
            Int(Double(charBudget) * Self.recentCharsRatio)
        )
        let availableTokens = max(0, tokenLimit - baseTokens)

        var recent: [String] = []
        var usedChars = 0
        var usedTokens = 0
        let tail = transcribedParts.suffix(Self.maxRecentChunks)
        for chunk in tail.reversed() {
            let sep = recent.isEmpty ? 0 : 1
            let neededChars = length(chunk) + sep
            if usedChars + neededChars > availableChars { break }
            let chunkTokens = tokenCounter.countTokens((sep == 1 ? " " : "") + chunk)
            if usedTokens + chunkTokens > availableTokens { break }
            recent.append(chunk)
            usedChars += neededChars
            usedTokens += chunkTokens
        }
        recent.reverse()

        return recent.isEmpty ? base : base + " " + recent.joined(separator: " ")
    }
}
