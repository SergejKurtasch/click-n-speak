import XCTest
import CNSCore
@testable import CNSDictionary

final class CorrectionAnalyzerTests: XCTestCase {
    func testHasFreshStrongCorrectionSignalEmpty() {
        let index = CorrectionIndex.defaultIndex()
        let result = CorrectionAnalyzer.hasFreshStrongCorrectionSignal(index: index, currentPhraseCount: 10)
        XCTAssertFalse(result)
    }

    func testCooldownBoundaryAndScriptLanguageUnions() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var index = CorrectionIndex.defaultIndex()
        index.insertedTerms["latin"]?["swiftui"] = InsertedTerm(
            term: "SwiftUI",
            count: 3,
            weightedCount: 3,
            firstSeen: ISOTimestamp.now(now),
            lastSeen: ISOTimestamp.now(now),
            lastSeenRow: 10
        )

        let skipped = ["de": ["swiftui": 0]]
        let blocked = CorrectionAnalyzer.getCorrectionCandidates(
            index: index,
            existingLowerByLang: [:],
            skippedLowerByLang: skipped,
            currentPhraseCount: 149,
            minCorrectionCount: ["latin": 2, "cyrillic": 2],
            cooldownPhrases: 150,
            now: now
        )
        XCTAssertNil(blocked["latin"])

        let released = CorrectionAnalyzer.getCorrectionCandidates(
            index: index,
            existingLowerByLang: [:],
            skippedLowerByLang: skipped,
            currentPhraseCount: 150,
            minCorrectionCount: ["latin": 2, "cyrillic": 2],
            cooldownPhrases: 150,
            now: now
        )
        XCTAssertEqual(released["latin"]?.map(\.term), ["SwiftUI"])

        let existingInAnotherLatinLanguage = CorrectionAnalyzer.getCorrectionCandidates(
            index: index,
            existingLowerByLang: ["fr": ["swiftui"]],
            skippedLowerByLang: [:],
            currentPhraseCount: 150,
            now: now
        )
        XCTAssertNil(existingInAnotherLatinLanguage["latin"])
    }

    func testLegacyIndexMigrationCleansReplacementPairs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("corrections.json")
        let json = #"{"schema_version":1,"processed_rows":2,"inserted_terms":{"en":{}},"replacement_pairs":{"en":[{"from":"API","to":"API","count":1,"last_seen":""},{"from":"ap eye","to":"API","count":2,"last_seen":"2026-01-01T00:00:00+00:00"}]}}"#
        try Data(json.utf8).write(to: url)

        let migrated = CorrectionAnalyzer.readIndex(at: url)
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.replacementPairs["latin"]?.count, 1)
        XCTAssertEqual(migrated.replacementPairs["latin"]?.first?.from, "ap eye")
    }

    func testIncrementalUpdateReadsOnlyNewBytesAndKeepsEqualTimestamps() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrections-offset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataset = directory.appendingPathComponent("dataset.jsonl")
        let indexURL = directory.appendingPathComponent("corrections.json")
        let timestamp = "2026-09-02T12:00:00+00:00"
        let first = #"{"timestamp":"2026-09-02T12:00:00+00:00","raw_whisper":"alpha","user_final":"AlphaOne"}"# + "\n"
        let second = #"{"timestamp":"2026-09-02T12:00:00+00:00","raw_whisper":"beta","user_final":"BetaTwo"}"# + "\n"
        try Data(first.utf8).write(to: dataset)

        let initial = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
            datasetPath: dataset,
            indexPath: indexURL
        )
        XCTAssertEqual(initial.processedRows, 1)
        XCTAssertEqual(initial.lastProcessedTs, timestamp)

        let handle = try FileHandle(forWritingTo: dataset)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.utf8))
        try handle.close()
        let updated = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
            datasetPath: dataset,
            indexPath: indexURL
        )

        XCTAssertEqual(updated.processedRows, 2)
        XCTAssertEqual(updated.lastProcessedOffset, UInt64(Data((first + second).utf8).count))
    }
}
