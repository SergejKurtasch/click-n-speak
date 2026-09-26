import Testing
import Foundation
@testable import CNSCore

@Suite("Config migrations")
struct ConfigMigrationTests {
    // Must match FIXED_NOW in spikes/config_migration_check/generate_expected.py.
    static let fixedNow = "2026-07-14T12:00:00.123456+00:00"

    private func loadObject(_ fixturePath: String) throws -> JSONObject {
        let value = try JSONValue.parse(data: Fixtures.data(fixturePath))
        return try #require(value.objectValue)
    }

    /// The core equivalence check (Phase 1.5 acceptance): the Swift migration
    /// chain produces the same result as the real Python functions, on each
    /// input fixture, using the same pinned timestamp and heuristic token counter.
    @Test("Swift chain matches Python output", arguments: [
        "legacy_v1", "real_v6", "v4_strings", "ua_legacy",
    ])
    func matchesPython(_ name: String) throws {
        let input = try loadObject("migration_inputs/\(name).json")
        let expected = try JSONValue.parse(data: Fixtures.data("migration_expected/\(name).json"))

        let migrated = Config.migrated(input, now: Self.fixedNow)
        let actual = JSONValue.object(migrated.raw)

        #expect(
            actual.semanticallyEqual(to: expected),
            "Migration of \(name) diverged from Python.\nExpected: \(expected.serializedPythonCompatible())\nActual: \(actual.serializedPythonCompatible())"
        )
    }

    @Test("All inputs reach schema_version 10")
    func reachesV10() throws {
        for name in ["legacy_v1", "real_v6", "v4_strings", "ua_legacy"] {
            let migrated = Config.migrated(try loadObject("migration_inputs/\(name).json"), now: Self.fixedNow)
            #expect(migrated.schemaVersion == 10, "\(name) did not reach v10")
        }
    }

    @Test("Schema 9 adds replacement policy defaults")
    func replacementPolicyDefaults() {
        var input = JSONObject()
        input["schema_version"] = .int(9)
        input["future_extension"] = .string("preserved")

        let migrated = Config.migrated(input, now: Self.fixedNow)

        #expect(migrated.schemaVersion == 10)
        #expect(migrated.raw["approved_auto_replacements"]?.arrayValue == [])
        #expect(migrated.raw["rejected_replacements"]?.arrayValue == [])
        #expect(migrated.raw["replacement_policy_initialized"]?.boolValue == false)
        #expect(migrated.raw["future_extension"]?.stringValue == "preserved")
    }

    @Test("Schema 10 replacement policy migration is idempotent")
    func replacementPolicyIdempotent() {
        var approval = JSONObject()
        approval["from"] = .string("Cogni")
        approval["to"] = .string("Cognee")
        approval["approved_at"] = .string(Self.fixedNow)
        var input = JSONObject()
        input["schema_version"] = .int(10)
        input["approved_auto_replacements"] = .array([.object(approval)])
        input["rejected_replacements"] = .array([])
        input["replacement_policy_initialized"] = .bool(true)

        let once = Config.migrated(input, now: Self.fixedNow)
        let twice = Config.migrated(once.raw, now: Self.fixedNow)

        #expect(JSONValue.object(once.raw).semanticallyEqual(to: .object(twice.raw)))
    }

    @Test("Migration is idempotent (re-running changes nothing)")
    func idempotent() throws {
        let once = Config.migrated(try loadObject("migration_inputs/legacy_v1.json"), now: Self.fixedNow)
        let twice = Config.migrated(once.raw, now: Self.fixedNow)
        #expect(JSONValue.object(once.raw).semanticallyEqual(to: .object(twice.raw)))
    }

    @Test("v5 converts legacy string terms to metadata dicts")
    func v5Conversion() throws {
        let migrated = Config.migrated(try loadObject("migration_inputs/v4_strings.json"), now: Self.fixedNow)
        let terms = try #require(migrated.raw["user_terms"]?.objectValue?["ru"]?.arrayValue)
        let first = try #require(terms.first?.objectValue)
        #expect(first["source"]?.stringValue == "manual")
        #expect(first["use_count"]?.intValue == 0)
        #expect(first["added_at"]?.stringValue == Self.fixedNow)
    }

    @Test("Ukrainian ua → uk folding merges terms and skipped_terms")
    func ukrainianNormalization() throws {
        let migrated = Config.migrated(try loadObject("migration_inputs/ua_legacy.json"), now: Self.fixedNow)
        #expect(migrated.primaryLanguage == "uk")
        // ua + uk user_terms merged into uk.
        let ukTerms = try #require(migrated.raw["user_terms"]?.objectValue?["uk"]?.arrayValue)
        #expect(ukTerms.count == 2)
        #expect(migrated.raw["user_terms"]?.objectValue?.contains("ua") == false)
        // skipped_terms merged with max count and canonical (lowercase) keys.
        let skipped = try #require(migrated.raw["skipped_terms"]?.objectValue?["uk"]?.objectValue)
        #expect(skipped["mlx"]?.intValue == 200)
        #expect(skipped["pca"]?.intValue == 50)
    }
}
