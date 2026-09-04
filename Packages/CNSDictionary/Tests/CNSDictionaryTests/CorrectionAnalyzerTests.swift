import XCTest
import CNSCore
@testable import CNSDictionary

final class CorrectionAnalyzerTests: XCTestCase {
    func testOpcodesHandlesEitherEmptySide() {
        let insertion = getOpcodes([String](), ["term"])
        XCTAssertEqual(insertion.count, 1)
        guard let insertionOpcode = insertion.first else { return }
        if case .insert = insertionOpcode.type {
            XCTAssertEqual(insertionOpcode.i1, 0)
            XCTAssertEqual(insertionOpcode.i2, 0)
            XCTAssertEqual(insertionOpcode.j1, 0)
            XCTAssertEqual(insertionOpcode.j2, 1)
        } else {
            XCTFail("Expected an insertion opcode")
        }

        let deletion = getOpcodes(["term"], [String]())
        XCTAssertEqual(deletion.count, 1)
        guard let deletionOpcode = deletion.first else { return }
        if case .delete = deletionOpcode.type {
            XCTAssertEqual(deletionOpcode.i1, 0)
            XCTAssertEqual(deletionOpcode.i2, 1)
            XCTAssertEqual(deletionOpcode.j1, 0)
            XCTAssertEqual(deletionOpcode.j2, 0)
        } else {
            XCTFail("Expected a deletion opcode")
        }
    }

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

    func testLegacyIndexMigrationRequestsDatasetRebuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("corrections.json")
        let json = #"{"schema_version":1,"processed_rows":2,"inserted_terms":{"en":{}},"replacement_pairs":{"en":[{"from":"API","to":"API","count":1,"last_seen":""},{"from":"ap eye","to":"API","count":2,"last_seen":"2026-01-01T00:00:00+00:00"}]}}"#
        try Data(json.utf8).write(to: url)

        let migrated = CorrectionAnalyzer.readIndex(at: url)
        XCTAssertEqual(migrated.schemaVersion, 4)
        XCTAssertEqual(migrated.processedRows, 0)
        XCTAssertTrue(migrated.replacementPairs["latin"]?.isEmpty == true)
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

    func testOneDatasetRowCountsAnInsertedTermOnlyOnceAcrossRawAndAIText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrections-dedup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataset = directory.appendingPathComponent("dataset.jsonl")
        let indexURL = directory.appendingPathComponent("corrections.json")
        let row = #"{"timestamp":"2026-09-02T12:00:00+00:00","raw_whisper":"Cogniz","ai_edited":"Cogni","user_final":"Cognee"}"# + "\n"
        try Data(row.utf8).write(to: dataset)

        let index = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
            datasetPath: dataset,
            indexPath: indexURL
        )

        XCTAssertEqual(index.insertedTerms["latin"]?["cognee"]?.count, 1)
    }

    func testCorrectionIndexHandlesUserFinalWithoutLetterTokens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrections-symbols-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataset = directory.appendingPathComponent("dataset.jsonl")
        let indexURL = directory.appendingPathComponent("corrections.json")
        let row = #"{"timestamp":"2026-09-02T12:00:00+00:00","raw_whisper":"six times seven equals forty two","ai_edited":"6 × 7 = 42","user_final":"6 × 7 = 42"}"# + "\n"
        try Data(row.utf8).write(to: dataset)

        let index = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
            datasetPath: dataset,
            indexPath: indexURL
        )

        XCTAssertEqual(index.processedRows, 1)
        XCTAssertTrue(index.insertedTerms["latin"]?.isEmpty == true)
        XCTAssertTrue(index.insertedTerms["cyrillic"]?.isEmpty == true)
    }

    func testCorrectionCandidatesRequireTechnicalShapeOrStableReplacement() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func inserted(_ term: String, count: Int) -> InsertedTerm {
            InsertedTerm(
                term: term,
                count: count,
                weightedCount: Double(count),
                firstSeen: ISOTimestamp.now(now),
                lastSeen: ISOTimestamp.now(now),
                lastSeenRow: count
            )
        }
        var index = CorrectionIndex.defaultIndex()
        index.insertedTerms["latin"] = [
            "cognee": inserted("Cognee", count: 17),
            "swiftui": inserted("SwiftUI", count: 5),
        ]
        index.insertedTerms["cyrillic"] = [
            "проанализируй": inserted("Проанализируй", count: 19),
            "какие-то": inserted("какие-то", count: 8),
            "проверь": inserted("Проверь", count: 8),
        ]
        index.replacementPairs["latin"] = [
            ReplacementPair(from: "Cogni", to: "Cognee", count: 9, lastSeen: ISOTimestamp.now(now)),
        ]
        index.replacementPairs["cyrillic"] = [
            ReplacementPair(from: "какие", to: "какие-то", count: 1, lastSeen: ISOTimestamp.now(now)),
        ]

        let candidates = CorrectionAnalyzer.getCorrectionCandidates(
            index: index,
            existingLowerByLang: [:],
            skippedLowerByLang: [:],
            currentPhraseCount: 100,
            minCorrectionCount: ["latin": 5, "cyrillic": 5],
            now: now
        )

        XCTAssertEqual(Set(candidates["latin"]?.map(\.term) ?? []), Set(["Cognee", "SwiftUI"]))
        XCTAssertNil(candidates["cyrillic"])
    }

    func testCandidateSeparatesEvidenceCountFromRankingScore() {
        let candidate = TermCandidate(
            term: "Cognee",
            count: 17,
            correctionCount: 17,
            frequencyCount: 0,
            source: "correction"
        )

        XCTAssertEqual(candidate.evidenceCount, 17)
        XCTAssertEqual(candidate.rankingScore, 170)
    }
}
