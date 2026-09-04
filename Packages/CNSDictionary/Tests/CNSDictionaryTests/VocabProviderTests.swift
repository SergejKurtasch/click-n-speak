import XCTest
import CNSCore
@testable import CNSDictionary

final class VocabProviderTests: XCTestCase {
    private func replacementValue(
        from: String,
        to: String,
        timestampKey: String = "added_at"
    ) -> JSONValue {
        var object = JSONObject()
        object["from"] = .string(from)
        object["to"] = .string(to)
        object[timestampKey] = .string("2026-09-01T00:00:00Z")
        return .object(object)
    }

    private func replacementConfig(
        manual: [(String, String)] = [],
        approved: [(String, String)] = [],
        rejected: [(String, String)] = []
    ) -> JSONValue {
        var object = JSONObject()
        object["manual_replacements"] = .array(manual.map {
            replacementValue(from: $0.0, to: $0.1)
        })
        object["approved_auto_replacements"] = .array(approved.map {
            replacementValue(from: $0.0, to: $0.1, timestampKey: "approved_at")
        })
        object["rejected_replacements"] = .array(rejected.map {
            replacementValue(from: $0.0, to: $0.1, timestampKey: "rejected_at")
        })
        return .object(object)
    }

    func testCollectKnownTerms() {
        let configRaw = """
        {
            "user_terms": {
                "en": [
                    {"term": "foo", "source": "manual", "use_count": 5},
                    {"term": "bar", "source": "manual", "use_count": 2}
                ]
            }
        }
        """

        let config = try! JSONValue.parse(configRaw)
        let list = VocabProvider.collectKnownTerms(config: config, languages: ["en"])

        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.contains("foo"))
        XCTAssertTrue(list.contains("bar"))
    }

    func testReplacementsUseLongestWholePhraseWithoutCascading() {
        let result = VocabProvider.applyReplacements(
            "Use ap eye client and ap eye, not ap eyesight.",
            pairs: [
                ("ap eye", "API"),
                ("ap eye client", "SDK"),
                ("API", "changed-again"),
            ]
        )
        XCTAssertEqual(result, "Use SDK and API, not ap eyesight.")
    }

    func testDirectReplacementsContainOnlyManualAndApprovedPairs() {
        let config = replacementConfig(
            manual: [("ap eye", "API")],
            approved: [
                ("ap eye", "API"),
                ("ap eye", "SDK"),
                ("Cogni", "Cognee"),
                ("Drylabs", "Drylabz"),
            ],
            rejected: [("Drylabs", "Drylabz")]
        )

        let result = VocabProvider.collectDirectReplacements(config: config)

        XCTAssertEqual(result.map(\.0), ["ap eye", "Cogni"])
    }

    func testEditorHintsIncludeRepeatedAndExcludeRejectedStaleAndSingles() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("corrections.json")
        var index = CorrectionIndex.defaultIndex()
        index.processedRows = 500
        index.replacementPairs["latin"] = [
            ReplacementPair(
                from: "single", to: "Single", count: 1,
                lastSeen: ISOTimestamp.now(now), lastSeenRow: 500
            ),
            ReplacementPair(
                from: "Cogni", to: "Cognee", count: 2,
                lastSeen: ISOTimestamp.now(now), lastSeenRow: 500
            ),
            ReplacementPair(
                from: "Drylabs", to: "Drylabz", count: 3,
                lastSeen: ISOTimestamp.now(now), lastSeenRow: 500
            ),
            ReplacementPair(
                from: "stale date", to: "Stale Date", count: 4,
                lastSeen: ISOTimestamp.now(now.addingTimeInterval(-90 * 86_400)), lastSeenRow: 500
            ),
            ReplacementPair(
                from: "stale rows", to: "Stale Rows", count: 5,
                lastSeen: ISOTimestamp.now(now), lastSeenRow: 200
            ),
        ]
        index.replacementPairs["cyrillic"] = [
            ReplacementPair(
                from: "когни", to: "Cognee", count: 3,
                lastSeen: ISOTimestamp.now(now), lastSeenRow: 500
            ),
        ]
        try CorrectionAnalyzer.writeIndex(index, to: url)
        let config = replacementConfig(
            manual: [("ap eye", "API")],
            rejected: [("Drylabs", "Drylabz")]
        )

        let english = VocabProvider.collectEditorHints(
            config: config,
            languages: ["en"],
            correctionsURL: url,
            now: now
        )
        XCTAssertEqual(english.map(\.0), ["ap eye", "Cogni"])
        XCTAssertFalse(english.contains { $0.0 == "Drylabs" })
        XCTAssertFalse(english.contains { $0.0 == "single" })
        XCTAssertFalse(english.contains { $0.0.hasPrefix("stale") })
        XCTAssertFalse(english.contains { $0.0 == "когни" })
    }

    func testReplacementQueriesFilterLanguagesAndApplyPriorityBeforeCap() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("corrections.json")
        var index = CorrectionIndex.defaultIndex()
        index.processedRows = 10
        index.replacementPairs["latin"] = [
            ReplacementPair(
                from: "third", to: "Third", count: 9,
                lastSeen: ISOTimestamp.now(now), lastSeenRow: 10
            ),
        ]
        try CorrectionAnalyzer.writeIndex(index, to: url)
        let config = replacementConfig(
            manual: [("first", "First"), ("первый", "Первый")],
            approved: [("second", "Second")]
        )

        XCTAssertEqual(
            VocabProvider.collectDirectReplacements(config: config, languages: ["en"]).map(\.0),
            ["first", "second"]
        )
        XCTAssertEqual(
            VocabProvider.collectEditorHints(
                config: config,
                languages: ["en"],
                cap: 2,
                correctionsURL: url,
                now: now
            ).map(\.0),
            ["first", "second"]
        )
    }
}
