import Foundation

/// Joins per-chunk Whisper texts into one phrase.
///
/// Ported from `_join_chunks` in `app.py`. Whisper punctuates every chunk
/// independently, so it often ends a non-final chunk with a full stop even
/// though the sentence continues. When the next chunk starts lowercase, that
/// stop is dropped.
public enum ChunkJoiner {
    public static func join(_ parts: [String]) -> String {
        guard parts.count > 1 else {
            return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = parts[0]
        for part in parts.dropFirst() {
            if let last = result.last, let first = part.first,
               ".!?".contains(last), first.isLowercase {
                result.removeLast()
            }
            result += " " + part
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
