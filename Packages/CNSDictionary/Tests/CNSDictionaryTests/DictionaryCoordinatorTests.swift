import CNSCore
import Foundation
import XCTest
@testable import CNSDictionary

@MainActor
final class DictionaryCoordinatorTests: XCTestCase {
    private func makePaths(_ name: String = UUID().uuidString) -> Paths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-dictionary-\(name)", isDirectory: true)
        return Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
    }

    private func makeConfig(mode: String = "disabled") -> Config {
        var object = JSONObject()
        object["schema_version"] = .int(9)
        object["primary_language"] = .string("en")
        object["additional_languages"] = .array([.string("ru")])
        object["prompt_update_mode"] = .string(mode)
        object["auto_prompt_check_interval"] = .int(1)
        object["auto_prompt_check_min_count_primary"] = .int(1)
        object["auto_prompt_check_min_count_additional"] = .int(1)
        object["auto_prompt_lookback"] = .int(300)
        object["user_terms"] = .object(JSONObject())
        return Config.migrated(object)
    }

    private func makeCoordinator(
        config: Config,
        paths: Paths,
        clock: @escaping @Sendable () -> Date = Date.init
    ) -> DictionaryCoordinator {
        DictionaryCoordinator(
            config: config,
            paths: paths,
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile),
            clock: clock
        )
    }

    private func record(finalText: String = "Sergej") -> DatasetRecord {
        DatasetRecord(
            rawWhisper: "search",
            aiEdited: nil,
            aiStatus: "disabled",
            sttBackend: "local",
            sttModel: "fixture-whisper",
            aiModel: nil,
            userFinal: finalText,
            lang: "en",
            promptHash: "fixture",
            userTerms: []
        )
    }

    func testFullLearningFlowAndConfirmIdempotency() async throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let paths = makePaths()
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths, clock: { date })
        let confirmation = DictionaryConfirmation(
            sessionID: 42,
            datasetRecord: record(),
            finalText: "Sergej",
            date: date
        )

        let first = await coordinator.recordConfirmation(confirmation)
        let duplicate = await coordinator.recordConfirmation(confirmation)
        let repeated = await coordinator.recordConfirmation(DictionaryConfirmation(
            sessionID: 43,
            datasetRecord: record(),
            finalText: "Sergej",
            date: date.addingTimeInterval(1)
        ))
        XCTAssertTrue(first.datasetSaved)
        XCTAssertTrue(first.correctionsUpdated)
        XCTAssertTrue(first.historySaved)
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertTrue(repeated.datasetSaved)
        XCTAssertEqual(PhraseHistory(fileURL: paths.phraseHistoryFile).count(), 2)
        XCTAssertEqual(try String(contentsOf: paths.datasetFile).split(separator: "\n").count, 2)

        try coordinator.setPromptUpdateMode("suggest")
        try await coordinator.runPromptAnalysis()
        XCTAssertEqual(coordinator.pendingSuggestions()["en"]?.map(\.term), ["Sergej"])

        try coordinator.acceptSuggestion(language: "en", term: "sergej")
        XCTAssertTrue(UserTerms.activeTerms(coordinator.snapshot, lang: "en").contains("Sergej"))
        XCTAssertTrue(coordinator.snapshot.initialPrompt.contains("Sergej"))
        XCTAssertTrue(try String(contentsOf: paths.initialPromptFile(lang: "en")).contains("Sergej"))
    }

    func testTermEditRevertAndPromptWatcherGuards() throws {
        let paths = makePaths()
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths)
        var invalidationCount = 0
        coordinator.onSnapshotChanged = { _, _ in invalidationCount += 1 }

        XCTAssertTrue(coordinator.addManualTerm("SwiftUI", language: "en"))
        XCTAssertEqual(invalidationCount, 1)
        coordinator.scanPromptFilesForTesting()
        XCTAssertEqual(invalidationCount, 1, "An app-owned prompt write must not be re-imported")

        try coordinator.editTerm(language: "en", oldTerm: "SwiftUI", newTerm: "SwiftData")
        XCTAssertTrue(coordinator.snapshot.initialPrompt.contains("SwiftData"))
        try coordinator.revert(language: "en")
        XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), ["SwiftUI"])

        try Data().write(to: paths.initialPromptFile(lang: "en"))
        coordinator.scanPromptFilesForTesting()
        XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), ["SwiftUI"])

        try Data([0xC3, 0x28]).write(to: paths.initialPromptFile(lang: "en"))
        coordinator.scanPromptFilesForTesting()
        XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), ["SwiftUI"])

        try Data("Alpha, alpha, Beta".utf8).write(to: paths.initialPromptFile(lang: "en"))
        coordinator.scanPromptFilesForTesting()
        XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), ["Alpha", "Beta"])
        XCTAssertTrue(coordinator.snapshot.initialPrompt.contains("Alpha"))
    }

    func testSuggestAutoAndDisabledModes() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for mode in ["suggest", "auto", "disabled"] {
            let paths = makePaths(mode)
            try paths.ensureDataDirectory()
            var index = CorrectionIndex.defaultIndex()
            index.processedRows = 2
            index.insertedTerms["latin"]?["swiftui"] = InsertedTerm(
                term: "SwiftUI",
                count: 2,
                weightedCount: 2,
                firstSeen: ISOTimestamp.now(now),
                lastSeen: ISOTimestamp.now(now),
                lastSeenRow: 2
            )
            try JSONEncoder().encode(index).write(to: paths.correctionsFile)
            let coordinator = makeCoordinator(config: makeConfig(mode: mode), paths: paths, clock: { now })

            try await coordinator.runPromptAnalysis()
            switch mode {
            case "suggest":
                XCTAssertEqual(coordinator.pendingSuggestions()["en"]?.map(\.term), ["SwiftUI"])
                XCTAssertEqual(coordinator.pendingSuggestions()["en"]?.first?.count, 2)
                XCTAssertTrue(UserTerms.activeTerms(coordinator.snapshot, lang: "en").isEmpty)
            case "auto":
                XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), ["SwiftUI"])
                XCTAssertTrue(coordinator.pendingSuggestions().isEmpty)
            default:
                XCTAssertTrue(UserTerms.activeTerms(coordinator.snapshot, lang: "en").isEmpty)
                XCTAssertTrue(coordinator.pendingSuggestions().isEmpty)
            }
        }
    }

    func testReplacementMutationsAreValidatedAndPersisted() throws {
        let paths = makePaths()
        final class Clock: @unchecked Sendable {
            var now: Date
            init(_ now: Date) { self.now = now }
        }
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000_000))
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths, clock: { clock.now })
        XCTAssertThrowsError(try coordinator.saveManualReplacements([("", "target")]))
        XCTAssertThrowsError(try coordinator.saveManualReplacements([("api", "API"), ("api", "SDK")]))

        try coordinator.saveManualReplacements([("ap eye", "API"), ("ap eye", "API")])
        var rows = coordinator.replacementRows()
        XCTAssertEqual(rows.filter { $0.source == "manual" }.count, 1)
        XCTAssertEqual(rows.first?.from, "ap eye")
        XCTAssertEqual(coordinator.snapshot.raw["manual_replacements"]?.arrayValue?.count, 1)

        let originalAddedAt = rows.first?.addedAt
        clock.now = clock.now.addingTimeInterval(86_400)
        try coordinator.saveManualReplacements([("ap eye", "API")])
        rows = coordinator.replacementRows()
        XCTAssertEqual(rows.first?.addedAt, originalAddedAt)
    }

    func testDailyMaintenanceUsesInjectedClockAndPersistsTimestamps() async throws {
        final class Clock: @unchecked Sendable {
            var now: Date
            init(_ now: Date) { self.now = now }
        }
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000_000))
        let paths = makePaths()
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths, clock: { clock.now })

        XCTAssertEqual(try coordinator.runDecayIfDue(), 0)
        XCTAssertEqual(try coordinator.runDecayIfDue(), 0)
        XCTAssertNotNil(coordinator.snapshot.raw["last_decay_run_ts"]?.stringValue)
        let firstMetrics = try await coordinator.runMetricsIfDue()
        XCTAssertNotNil(firstMetrics)
        XCTAssertEqual(Metrics.loadHistory(at: paths.metricsHistoryFile).count, 1)
        let cachedMetrics = try await coordinator.runMetricsIfDue()
        XCTAssertNotNil(cachedMetrics)
        XCTAssertEqual(Metrics.loadHistory(at: paths.metricsHistoryFile).count, 1)

        clock.now = clock.now.addingTimeInterval(24 * 3_600)
        let nextMetrics = try await coordinator.runMetricsIfDue()
        XCTAssertNotNil(nextMetrics)
        XCTAssertEqual(Metrics.loadHistory(at: paths.metricsHistoryFile).count, 2)
    }
}
