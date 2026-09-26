import Foundation
import Testing
@testable import CNSCore

@Suite("Swift configuration migration compatibility")
struct ParityDataCompatibilityTests {
    private static let fixedNow = "2026-07-14T12:00:00.123456+00:00"

    private func schemaFixtures() throws -> [[String: Any]] {
        let url = try #require(Bundle.module.url(
            forResource: "config_schemas", withExtension: "json", subdirectory: "Fixtures"
        ))
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return try #require(root["fixtures"] as? [[String: Any]])
    }

    private func object(from raw: [String: Any]) throws -> JSONObject {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try #require(JSONValue.parse(data: data).objectValue)
    }

    @Test("Every supported schema migrates and round-trips through Swift")
    func schemaMigrationRoundTrip() throws {
        let fixtures = try schemaFixtures()
        #expect(Set(fixtures.compactMap { $0["id"] as? String }).count == 10)

        for fixture in fixtures {
            let fixtureID = try #require(fixture["id"] as? String)
            let rawConfig = try #require(fixture["config"] as? [String: Any])
            let migrated = Config.migrated(try object(from: rawConfig), now: Self.fixedNow)
            #expect(migrated.schemaVersion == 10, "Migration failed for \(fixtureID)")
            #expect(migrated.raw["future_extension"]?.objectValue?["owner"]?.stringValue == "parity")

            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("cns-swift-parity-\(fixtureID)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let saved = temporary.appendingPathComponent("config.json")
            try migrated.saveAtomically(to: saved)
            let reloaded = Config.load(from: saved)
            #expect(reloaded.schemaVersion == 10)
            #expect(reloaded.raw["future_extension"]?.objectValue?["owner"]?.stringValue == "parity")

            if fixtureID == "schema-v10" {
                let expected = try object(from: rawConfig)
                #expect(reloaded.raw["approved_auto_replacements"] == expected["approved_auto_replacements"])
                #expect(reloaded.raw["rejected_replacements"] == expected["rejected_replacements"])
            }
        }
    }

    @Test("Malformed migration input remains byte-for-byte recoverable")
    func malformedOriginalIsUntouched() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrupt-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let corrupt = Data("{not valid json".utf8)
        try corrupt.write(to: temporary)

        let fallback = Config.load(from: temporary)
        #expect(fallback.schemaVersion == 10)
        #expect(try Data(contentsOf: temporary) == corrupt)
    }
}
