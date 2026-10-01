import Foundation

public enum LogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

/// Appends log lines in the exact format the Python app uses
/// (`%(asctime)s - %(levelname)s - %(message)s`, e.g.
/// `2026-07-14 10:20:30,123 - INFO - message`) so the shared log file and the
/// `scripts/analyze_runtime_log.py` parser keep working. Serialised through an
/// actor; recreates the file if it is deleted while running (WatchedFileHandler
/// behaviour).
public actor FileLogger {
    private let fileURL: URL
    private let alsoConsole: Bool

    public init(fileURL: URL, alsoConsole: Bool = true) {
        self.fileURL = fileURL
        self.alsoConsole = alsoConsole
    }

    public func log(_ level: LogLevel, _ message: String) {
        let line = "\(Self.timestamp()) - \(level.rawValue) - \(message)\n"
        append(line)
        if alsoConsole {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    public func info(_ message: String) { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String) { log(.error, message) }
    public func runtimeEvent(_ json: String) { info("runtime_event \(json)") }

    private func append(_ line: String) {
        let data = Data(line.utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            fm.createFile(atPath: fileURL.path, contents: data)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Match Python `logging.Formatter` default `asctime`:
    /// `YYYY-MM-DD HH:MM:SS,mmm` in local time.
    nonisolated static func timestamp(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let millis = (c.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d,%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis
        )
    }
}
