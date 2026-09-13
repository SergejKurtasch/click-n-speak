import Testing
import Foundation
@testable import CNSCore

@Suite("Config Recording Settings")
struct ConfigRecordingSettingsTests {
    private func config(_ values: [String: JSONValue]) throws -> Config {
        let json = JSONValue.object(JSONObject([("schema_version", .int(10))] + values.map { $0 }))
        let data = Data(json.serializedPythonCompatible(indent: 0).utf8)
        return try Config(validating: data)
    }

    @Test("Defaults are applied when fields are missing")
    func defaults() throws {
        let cfg = try config([:])
        let settings = try cfg.recordingSettings
        #expect(settings.silenceDurationLimit == 1.0)
        #expect(settings.targetChunkDuration == 10.0)
        #expect(settings.minChunkDuration == 2.0)
        #expect(settings.maxChunkDuration == 20.0)
    }

    @Test("Valid custom values (including integer JSON)")
    func customValues() throws {
        let cfg = try config([
            "silence_duration_limit": .double(1.5),
            "target_chunk_duration": .int(15), // integer JSON
            "min_chunk_duration": .double(3.0),
            "max_chunk_duration": .int(25)
        ])
        let settings = try cfg.recordingSettings
        #expect(settings.silenceDurationLimit == 1.5)
        #expect(settings.targetChunkDuration == 15.0)
        #expect(settings.minChunkDuration == 3.0)
        #expect(settings.maxChunkDuration == 25.0)
    }
    
    @Test("Valid boundary: target = max")
    func boundaryValues() throws {
        let cfg = try config([
            "target_chunk_duration": .int(10),
            "max_chunk_duration": .int(10)
        ])
        let settings = try cfg.recordingSettings
        #expect(settings.targetChunkDuration == 10.0)
        #expect(settings.maxChunkDuration == 10.0)
    }

    @Test("Wrong type yields invalidType")
    func wrongType() async throws {
        #expect(throws: RecordingSettingsError.invalidType(field: "silence_duration_limit")) {
            _ = try config(["silence_duration_limit": .string("1.5")])
        }
    }

    @Test("Null is treated as missing and uses default")
    func nullValue() throws {
        let cfg = try config(["target_chunk_duration": .null])
        let settings = try cfg.recordingSettings
        #expect(settings.targetChunkDuration == 10.0)
    }

    @Test("Zero or negative values")
    func zeroNegative() async throws {
        #expect(throws: RecordingSettingsError.nonPositive(field: "silence_duration_limit")) {
            _ = try config(["silence_duration_limit": .double(0.0)])
        }
        #expect(throws: RecordingSettingsError.nonPositive(field: "target_chunk_duration")) {
            _ = try config(["target_chunk_duration": .double(-5.0)])
        }
        #expect(throws: RecordingSettingsError.invalidOrdering) {
            _ = try config(["min_chunk_duration": .double(-1.0)])
        }
    }

    @Test("Violation of min <= target <= max")
    func orderViolation() async throws {
        #expect(throws: RecordingSettingsError.invalidOrdering) {
            _ = try config([
                "min_chunk_duration": .int(5),
                "target_chunk_duration": .int(4),
                "max_chunk_duration": .int(20)
            ])
        }
        #expect(throws: RecordingSettingsError.invalidOrdering) {
            _ = try config([
                "min_chunk_duration": .int(2),
                "target_chunk_duration": .int(10),
                "max_chunk_duration": .int(9)
            ])
        }
    }
}
