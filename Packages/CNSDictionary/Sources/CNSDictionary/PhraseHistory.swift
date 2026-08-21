import CNSCore
import Foundation

/// Append-only log of confirmed phrases, one per dictation session.
///
/// Ported from `phrase_history.py`. The file format is TSV
/// (`YYYY-MM-DDTHH:MM:SS\ttext`) and is shared with the Python app and the
/// analysis scripts, so it stays byte-identical.
public final class PhraseHistory: @unchecked Sendable {
    // @unchecked Sendable: `cachedCount` is guarded by `lock`; the file itself is
    // append-only, so concurrent appends cannot interleave a partial line.
    private let fileURL: URL
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var cachedCount: Int?

    public init(fileURL: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.log = log
    }

    /// Append one phrase. Newlines collapse to spaces; blank text is dropped.
    public func append(_ text: String, at date: Date = Date()) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !normalized.isEmpty else { return }

        let line = Self.timestamp(date) + "\t" + normalized + "\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try appendToFile(line)
            if let count = cachedCount {
                cachedCount = count + 1
            } else {
                cachedCount = countLines()
            }
        } catch {
            log("Failed to append phrase to \(fileURL.path): \(error)")
        }
    }

    /// Total phrases stored. O(1) after the first call.
    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let cachedCount { return cachedCount }
        let counted = countLines()
        cachedCount = counted
        return counted
    }

    /// Up to `n` most recent phrases as (timestamp, text), oldest first.
    public func lastPhrases(_ n: Int) -> [(timestamp: String, text: String)] {
        guard n > 0, let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(n).compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else {
                log("Skipping malformed phrase history line: \(line.prefix(80))…")
                return nil
            }
            return (String(line[line.startIndex..<tab]), String(line[line.index(after: tab)...]))
        }
    }

    // MARK: - Internals

    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    private func appendToFile(_ line: String) throws {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func countLines() -> Int {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}
