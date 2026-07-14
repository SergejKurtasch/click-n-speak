import Foundation

/// Runtime file locations. Mirrors the path table in CLAUDE.md and the
/// `get_*_path` helpers in `utils.py`.
///
/// Two modes protect the user's live data during migration development
/// (see docs/migration/CONVENTIONS.md, "Данные"):
/// - `.release` → the production Application Support directory the Python app uses.
/// - `.dev` → a sibling `Click-n-speak-dev` directory (or `CNS_DATA_DIR`), so a
///   debug build never reads or writes the real config/history/log.
public struct Paths: Sendable {
    public enum Mode: Sendable {
        case release
        case dev
    }

    public let mode: Mode
    public let dataDirectory: URL

    public init(mode: Mode, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.mode = mode
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        switch mode {
        case .release:
            dataDirectory = appSupport.appendingPathComponent("Click-n-speak", isDirectory: true)
        case .dev:
            if let override = environment["CNS_DATA_DIR"], !override.isEmpty {
                dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                dataDirectory = appSupport.appendingPathComponent("Click-n-speak-dev", isDirectory: true)
            }
        }
    }

    /// Resolve the mode from the build/runtime context: DEBUG builds and any run
    /// with `CNS_DATA_DIR` set use dev mode; release builds use production paths.
    public static func resolveDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        #if DEBUG
        return Paths(mode: .dev, environment: environment)
        #else
        if environment["CNS_DATA_DIR"] != nil {
            return Paths(mode: .dev, environment: environment)
        }
        return Paths(mode: .release, environment: environment)
        #endif
    }

    public var configFile: URL { dataDirectory.appendingPathComponent("config.json") }
    public var phraseHistoryFile: URL { dataDirectory.appendingPathComponent("phrase_history.txt") }
    public var correctionsFile: URL { dataDirectory.appendingPathComponent("corrections.json") }
    public var metricsHistoryFile: URL { dataDirectory.appendingPathComponent("metrics_history.jsonl") }
    public var setupDoneFile: URL { dataDirectory.appendingPathComponent("setup_done") }
    public var instanceLockFile: URL { dataDirectory.appendingPathComponent(".instance.lock") }

    public func initialPromptFile(lang: String) -> URL {
        dataDirectory.appendingPathComponent("initial_prompt_\(lang).txt")
    }

    /// Log file. In release mode this is the shared Python log path
    /// (`~/Library/Logs/Click-n-speak.log`); in dev mode the log is diverted
    /// into the dev data directory so it never appends to the production log
    /// (deliberate divergence from Python, which always uses the shared path).
    public var logFile: URL {
        switch mode {
        case .release:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Click-n-speak.log")
        case .dev:
            return dataDirectory.appendingPathComponent("Click-n-speak.log")
        }
    }

    /// Dataset JSONL lives in the home directory in the Python app
    /// (`~/.clicknspeak_dataset.jsonl`); dev mode diverts it too.
    public var datasetFile: URL {
        switch mode {
        case .release:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".clicknspeak_dataset.jsonl")
        case .dev:
            return dataDirectory.appendingPathComponent("clicknspeak_dataset.jsonl")
        }
    }

    /// Create the data directory if missing.
    public func ensureDataDirectory() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }
}
