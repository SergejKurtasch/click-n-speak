import sys

with open("Packages/CNSCore/Sources/CNSCore/Config.swift", "r") as f:
    content = f.read()

# patch Config.init(validating:)
old_init = """        guard case let .object(object) = value else {
            throw LoadError.decode("Configuration root must be an object")
        }
        self = Self.migrated(object)
    }"""
new_init = """        guard case let .object(object) = value else {
            throw LoadError.decode("Configuration root must be an object")
        }
        self = Self.migrated(object)
        _ = try self.recordingSettings
    }"""
content = content.replace(old_init, new_init)

# add recordingSettings
settings = """    public var sttModelName: String {
        raw["model_name"]?.stringValue ?? "mlx-community/whisper-large-v3-turbo"
    }

    public var recordingSettings: RecordingSettings {
        get throws {
            let silence = try readDouble("silence_duration_limit") ?? 1.0
            let target = try readDouble("target_chunk_duration") ?? 10.0
            let minC = try readDouble("min_chunk_duration") ?? 2.0
            let maxC = try readDouble("max_chunk_duration") ?? 20.0
            
            guard silence > 0 else { throw RecordingSettingsError.nonPositive(field: "silence_duration_limit") }
            guard target > 0 else { throw RecordingSettingsError.nonPositive(field: "target_chunk_duration") }
            guard silence.isFinite else { throw RecordingSettingsError.nonFinite(field: "silence_duration_limit") }
            guard target.isFinite else { throw RecordingSettingsError.nonFinite(field: "target_chunk_duration") }
            guard minC.isFinite else { throw RecordingSettingsError.nonFinite(field: "min_chunk_duration") }
            guard maxC.isFinite else { throw RecordingSettingsError.nonFinite(field: "max_chunk_duration") }
            
            guard minC >= 0, minC <= target, target <= maxC else {
                throw RecordingSettingsError.invalidOrdering
            }
            
            return RecordingSettings(
                silenceDurationLimit: silence,
                targetChunkDuration: target,
                minChunkDuration: minC,
                maxChunkDuration: maxC
            )
        }
    }
    
    private func readDouble(_ key: String) throws -> Double? {
        guard let value = raw[key] else { return nil }
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .null: return nil
        default: throw RecordingSettingsError.invalidType(field: key)
        }
    }
"""
content = content.replace("    public var sttModelName: String {\n        raw[\"model_name\"]?.stringValue ?? \"mlx-community/whisper-large-v3-turbo\"\n    }", settings)

with open("Packages/CNSCore/Sources/CNSCore/Config.swift", "w") as f:
    f.write(content)
