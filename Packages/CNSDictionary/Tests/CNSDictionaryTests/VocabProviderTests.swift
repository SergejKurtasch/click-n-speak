import XCTest
import CNSCore
@testable import CNSDictionary

final class VocabProviderTests: XCTestCase {
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

    func testInjectedCorrectionsPathFiltersByScriptAndThreshold() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("corrections.json")
        var index = CorrectionIndex.defaultIndex()
        index.replacementPairs["latin"] = [
            ReplacementPair(from: "ap eye", to: "API", count: 3, lastSeen: "2026-01-01T00:00:00+00:00"),
        ]
        index.replacementPairs["cyrillic"] = [
            ReplacementPair(from: "свифт ю ай", to: "SwiftUI", count: 4, lastSeen: "2026-01-01T00:00:00+00:00"),
        ]
        try JSONEncoder().encode(index).write(to: url)

        let english = VocabProvider.collectMisrecognitions(
            languages: ["en"],
            correctionsURL: url
        )
        XCTAssertEqual(english.map(\.0), ["ap eye"])
        XCTAssertTrue(VocabProvider.collectMisrecognitions(
            languages: ["en"],
            minCount: 5,
            correctionsURL: url
        ).isEmpty)
    }
}
