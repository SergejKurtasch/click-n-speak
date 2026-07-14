import Foundation

/// Typed facade over the dynamic config JSON. The underlying `JSONObject`
/// preserves every key (including unknown hand-edited ones) across a read/write
/// round-trip, mirroring the Python dict-based config. Typed accessors are
/// provided for the keys the app reads frequently; everything else stays
/// accessible via `raw`.
public struct Config: Sendable, Equatable {
    public var raw: JSONObject

    public init(raw: JSONObject = JSONObject()) {
        self.raw = raw
    }

    // MARK: - Load / migrate / save

    public enum LoadError: Error, Sendable {
        case decode(String)
    }

    /// Read config.json, run the full migration chain, and return the migrated
    /// config. Missing file yields an empty (fully migrated) config, matching
    /// the Python `load_config` behaviour.
    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url) else {
            return migrated(JSONObject())
        }
        guard let value = try? JSONValue.parse(data: data), case let .object(obj) = value else {
            return migrated(JSONObject())
        }
        return migrated(obj)
    }

    /// Apply the migration chain v2→v9 + Ukrainian normalization + the extra
    /// `setdefault`s from `load_config_data`. `now` and `promptBuilder` are
    /// injectable for deterministic testing against Python's output.
    public static func migrated(
        _ input: JSONObject,
        now: String = ISOTimestamp.now(),
        promptBuilder: InitialPromptBuilder = InitialPromptBuilder()
    ) -> Config {
        var obj = input
        let builder = promptBuilder
        ConfigMigrations.migrateToV2(&obj, promptBuilder: builder)
        ConfigMigrations.migrateToV3(&obj, promptBuilder: builder)
        ConfigMigrations.migrateToV4(&obj, promptBuilder: builder)
        ConfigMigrations.migrateToV5(&obj, promptBuilder: builder, now: now)
        ConfigMigrations.migrateToV6(&obj)
        ConfigMigrations.migrateToV7(&obj)
        ConfigMigrations.migrateToV8(&obj)
        ConfigMigrations.migrateToV9(&obj)
        ConfigMigrations.normalizeUkrainianLangCodes(&obj)
        obj.setDefault("last_metrics_snapshot_ts", .null)
        obj.setDefault("notify_on_metrics", .bool(true))
        obj.setDefault("last_metrics_notification_ts", .null)
        return Config(raw: obj)
    }

    /// Serialize matching Python's `json.dump(config, f, indent=4)`.
    public func serialized() -> String {
        JSONValue.object(raw).serializedPythonCompatible(indent: 4)
    }

    /// Atomically write config.json (sibling temp file + rename + fsync),
    /// matching `write_json_atomic`.
    public func saveAtomically(to url: URL) throws {
        try AtomicFile.writeText(serialized(), to: url)
    }

    // MARK: - Typed accessors

    /// `get_primary_language`.
    public static func primaryLanguage(_ obj: JSONObject) -> String {
        if let primary = obj["primary_language"]?.stringValue, !primary.isEmpty {
            return LanguageCode.normalize(primary)
        }
        if let list = obj["languages"]?.arrayValue, let first = list.first?.stringValue {
            return LanguageCode.normalize(first)
        }
        return "ru"
    }

    public var primaryLanguage: String { Config.primaryLanguage(raw) }

    public var additionalLanguages: [String] {
        (raw["additional_languages"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public var schemaVersion: Int {
        Int(raw["schema_version"]?.intValue ?? 1)
    }

    public var languagePickerDone: Bool {
        raw["language_picker_done"]?.boolValue ?? false
    }

    public var sttBackend: String {
        raw["stt_backend"]?.stringValue ?? "local"
    }

    public var aiEditorEnabled: Bool {
        raw["ai_editor_enabled"]?.boolValue ?? false
    }

    public var autostart: Bool {
        raw["autostart"]?.boolValue ?? false
    }

    public var initialPrompt: String {
        raw["initial_prompt"]?.stringValue ?? ""
    }
}
