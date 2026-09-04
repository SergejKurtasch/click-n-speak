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
        XCTAssertEqual(migrated.schemaVersion, 5)
        XCTAssertEqual(migrated.processedRows, 0)
        XCTAssertTrue(migrated.replacementPairs["latin"]?.isEmpty == true)
    }

    func testSchemaFourReplacementPairsRebuildWithLastSeenRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrections-schema-five-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataset = directory.appendingPathComponent("dataset.jsonl")
        let indexURL = directory.appendingPathComponent("corrections.json")
        let rows = [
            #"{"timestamp":"2026-09-02T12:00:00+00:00","raw_whisper":"Cogni","user_final":"Cognee"}"#,
            #"{"timestamp":"2026-09-03T12:00:00+00:00","raw_whisper":"Cogni","user_final":"Cognee"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(rows.utf8).write(to: dataset)
        let legacy = #"{"schema_version":4,"processed_rows":99,"inserted_terms":{"latin":{},"cyrillic":{}},"replacement_pairs":{"latin":[{"from":"Cogni","to":"Cognee","count":99,"last_seen":"2026-09-03T12:00:00+00:00"}],"cyrillic":[]}}"#
        try Data(legacy.utf8).write(to: indexURL)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T12:00:00+00:00"))

        let rebuilt = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
            datasetPath: dataset,
            indexPath: indexURL,
            now: now
        )

        XCTAssertEqual(rebuilt.schemaVersion, 5)
        XCTAssertEqual(rebuilt.processedRows, 2)
        let pair = try XCTUnwrap(rebuilt.replacementPairs["latin"]?.first)
        XCTAssertEqual(pair.count, 2)
        XCTAssertEqual(pair.lastSeenRow, 2)
    }

    func testReplacementPairStalenessUsesEitherInclusiveBoundary() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-04T12:00:00+00:00"))
        let fresh = ReplacementPair(
            from: "Cogni",
            to: "Cognee",
            count: 2,
            lastSeen: "2026-06-07T12:00:01+00:00",
            lastSeenRow: 701
        )
        let oldByDate = ReplacementPair(
            from: "Drylabs",
            to: "Drylabz",
            count: 2,
            lastSeen: "2026-06-06T12:00:00+00:00",
            lastSeenRow: 999
        )
        let oldByRows = ReplacementPair(
            from: "continue",
            to: "Continue",
            count: 2,
            lastSeen: "2026-09-04T12:00:00+00:00",
            lastSeenRow: 700
        )

        XCTAssertFalse(CorrectionAnalyzer.isReplacementPairStale(fresh, processedRows: 1_000, now: now))
        XCTAssertTrue(CorrectionAnalyzer.isReplacementPairStale(oldByDate, processedRows: 1_000, now: now))
        XCTAssertTrue(CorrectionAnalyzer.isReplacementPairStale(oldByRows, processedRows: 1_000, now: now))
    }

    func testPruneStaleReplacementPairsRemovesEitherExpiredKind() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T12:00:00+00:00"))
        var index = CorrectionIndex.defaultIndex()
        index.processedRows = 1_000
        index.replacementPairs["latin"] = [
            ReplacementPair(from: "fresh", to: "Fresh", count: 2, lastSeen: "2026-09-04T12:00:00+00:00", lastSeenRow: 999),
            ReplacementPair(from: "old rows", to: "Old rows", count: 2, lastSeen: "2026-09-04T12:00:00+00:00", lastSeenRow: 700),
            ReplacementPair(from: "old date", to: "Old date", count: 2, lastSeen: "2026-06-06T12:00:00+00:00", lastSeenRow: 999),
        ]

        let removed = CorrectionAnalyzer.pruneStaleReplacementPairs(in: &index, now: now)

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(index.replacementPairs["latin"]?.map(\.from), ["fresh"])
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
