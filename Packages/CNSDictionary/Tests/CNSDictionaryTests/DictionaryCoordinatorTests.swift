import CNSCore
import Foundation
import XCTest
@testable import CNSDictionary

@MainActor
final class DictionaryCoordinatorTests: XCTestCase {
    private enum FixtureError: Error {
        case correctionIndexWriteFailed
    }

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
        var config = Config.migrated(object)
        config.raw["replacement_policy_initialized"] = .bool(true)
        return config
    }

    private func writeReplacementIndex(
        _ pairs: [ReplacementPair],
        processedRows: Int,
        to url: URL
    ) throws {
        var index = CorrectionIndex.defaultIndex()
        index.processedRows = processedRows
        index.replacementPairs["latin"] = pairs
        try CorrectionAnalyzer.writeIndex(index, to: url)
    }

    private func replacementDecision(from: String, to: String, timestampKey: String, timestamp: String) -> JSONValue {
        var object = JSONObject()
        object["from"] = .string(from)
        object["to"] = .string(to)
        object[timestampKey] = .string(timestamp)
        return .object(object)
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

    func testReplacementSectionsHideSinglesAndClassifyRepeatedPairs() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let timestamp = ISOTimestamp.now(now)
        let paths = makePaths()
        try writeReplacementIndex([
            ReplacementPair(from: "once", to: "Once", count: 1, lastSeen: timestamp, lastSeenRow: 10),
            ReplacementPair(from: "twice", to: "Twice", count: 2, lastSeen: timestamp, lastSeenRow: 10),
            ReplacementPair(from: "thrice", to: "Thrice", count: 3, lastSeen: timestamp, lastSeenRow: 10),
        ], processedRows: 10, to: paths.correctionsFile)
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths, clock: { now })

        let sections = coordinator.replacementSections()

        XCTAssertTrue(sections.active.isEmpty)
        XCTAssertEqual(sections.candidates.map(\.from), ["thrice", "twice"])
        XCTAssertEqual(sections.candidates.map(\.state), [.readyForReview, .candidate])
        XCTAssertFalse(sections.candidates.contains { $0.from == "once" })
    }

    func testFirstPolicyInitializationApprovesExistingFrequentPairsExactlyOnce() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let timestamp = ISOTimestamp.now(now)
        let paths = makePaths()
        try writeReplacementIndex([
            ReplacementPair(from: "Cogni", to: "Cognee", count: 3, lastSeen: timestamp, lastSeenRow: 10),
            ReplacementPair(from: "twice", to: "Twice", count: 2, lastSeen: timestamp, lastSeenRow: 10),
        ], processedRows: 10, to: paths.correctionsFile)
        var pending = makeConfig()
        pending.raw["replacement_policy_initialized"] = .bool(false)

        let first = makeCoordinator(config: pending, paths: paths, clock: { now })

        XCTAssertTrue(first.snapshot.raw["replacement_policy_initialized"]?.boolValue == true)
        XCTAssertEqual(first.replacementSections().active.map(\.from), ["Cogni"])
        XCTAssertEqual(first.replacementSections().candidates.map(\.from), ["twice"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configFile.path))

        let active = try XCTUnwrap(first.replacementSections().active.first)
        try first.rejectReplacement(active)
        let reloaded = Config.load(from: paths.configFile)
        let second = makeCoordinator(config: reloaded, paths: paths, clock: { now })

        XCTAssertTrue(second.replacementSections().active.isEmpty)
        XCTAssertEqual(second.replacementSections().rejected.map(\.from), ["Cogni"])
    }

    func testPolicyInitializationRetriesWhenExistingIndexCannotBeRebuilt() throws {
        for fixture in ["malformed", "schema4"] {
            let paths = makePaths(fixture)
            try paths.ensureDataDirectory()
            if fixture == "malformed" {
                try Data("{not-json".utf8).write(to: paths.correctionsFile)
            } else {
                var index = CorrectionIndex.defaultIndex()
                index.schemaVersion = 4
                try CorrectionAnalyzer.writeIndex(index, to: paths.correctionsFile)
            }
            var pending = makeConfig()
            pending.raw["replacement_policy_initialized"] = .bool(false)

            let coordinator = makeCoordinator(config: pending, paths: paths)

            XCTAssertFalse(
                coordinator.snapshot.raw["replacement_policy_initialized"]?.boolValue ?? false,
                "Fixture \(fixture) must remain eligible for a later retry"
            )
        }
    }

    func testPolicyInitializationKeepsHighestCountTargetForConflictingSource() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let timestamp = ISOTimestamp.now(now)
        let paths = makePaths()
        try writeReplacementIndex([
            ReplacementPair(from: "Cogni", to: "Cogney", count: 3, lastSeen: timestamp, lastSeenRow: 10),
            ReplacementPair(from: "Cogni", to: "Cognee", count: 8, lastSeen: timestamp, lastSeenRow: 10),
        ], processedRows: 10, to: paths.correctionsFile)
        var pending = makeConfig()
        pending.raw["replacement_policy_initialized"] = .bool(false)

        let coordinator = makeCoordinator(config: pending, paths: paths, clock: { now })

        XCTAssertEqual(coordinator.replacementSections().active.map(\.to), ["Cognee"])
    }

    func testReplacementSectionPruningIsSerializedWithConfirmationUpdates() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let paths = makePaths()
        try writeReplacementIndex([
            ReplacementPair(from: "old", to: "Old", count: 4, lastSeen: "2000-01-01T00:00:00Z", lastSeenRow: 10),
        ], processedRows: 10, to: paths.correctionsFile)
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths, clock: { now })

        XCTAssertTrue(coordinator.replacementSections().candidates.isEmpty)
        let persisted = await coordinator.recordConfirmation(DictionaryConfirmation(
            sessionID: 77,
            datasetRecord: record(),
            finalText: "Sergej",
            date: now
        ))
        XCTAssertTrue(persisted.correctionsUpdated)

        var index = CorrectionAnalyzer.readIndex(at: paths.correctionsFile)
        for _ in 0..<50 where index.replacementPairs["latin"]?.contains(where: { $0.from == "old" }) == true {
            try await Task.sleep(for: .milliseconds(10))
            index = CorrectionAnalyzer.readIndex(at: paths.correctionsFile)
        }
        XCTAssertFalse(index.replacementPairs["latin"]?.contains(where: { $0.from == "old" }) ?? true)
        XCTAssertTrue(index.replacementPairs["latin"]?.contains(where: {
            $0.from == "search" && $0.to == "Sergej"
        }) ?? false)
        XCTAssertEqual(index.processedRows, 11)
    }

    func testPolicyInitializationFinalizesOnlyAfterPrunedIndexIsPersisted() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let paths = makePaths()
        try writeReplacementIndex([
            ReplacementPair(from: "fresh", to: "Fresh", count: 3, lastSeen: ISOTimestamp.now(now), lastSeenRow: 10),
            ReplacementPair(from: "old", to: "Old", count: 3, lastSeen: "2000-01-01T00:00:00Z", lastSeenRow: 10),
        ], processedRows: 10, to: paths.correctionsFile)
        var pending = makeConfig()
        pending.raw["replacement_policy_initialized"] = .bool(false)

        let coordinator = DictionaryCoordinator(
            config: pending,
            paths: paths,
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile),
            clock: { now },
            correctionIndexWriter: { _, _ in throw FixtureError.correctionIndexWriteFailed }
        )

        XCTAssertFalse(coordinator.snapshot.raw["replacement_policy_initialized"]?.boolValue ?? true)
        XCTAssertEqual(coordinator.snapshot.raw["approved_auto_replacements"]?.arrayValue?.count, 2)
        let persisted = Config.load(from: paths.configFile)
        XCTAssertFalse(persisted.raw["replacement_policy_initialized"]?.boolValue ?? true)
        XCTAssertEqual(persisted.raw["approved_auto_replacements"]?.arrayValue?.count, 2)
    }

    func testReplacementSectionsSortEveryStateByCountThenCanonicalKey() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let timestamp = ISOTimestamp.now(now)
        let paths = makePaths()
        try writeReplacementIndex([
            ReplacementPair(from: "active-low", to: "Active Low", count: 2, lastSeen: timestamp, lastSeenRow: 10),
            ReplacementPair(from: "active-high", to: "Active High", count: 7, lastSeen: timestamp, lastSeenRow: 10),
            ReplacementPair(from: "reject-low", to: "Reject Low", count: 3, lastSeen: timestamp, lastSeenRow: 10),
            ReplacementPair(from: "reject-high", to: "Reject High", count: 9, lastSeen: timestamp, lastSeenRow: 10),
        ], processedRows: 10, to: paths.correctionsFile)
        var config = makeConfig()
        config.raw["manual_replacements"] = .array([
            replacementDecision(from: "active-low", to: "Active Low", timestampKey: "added_at", timestamp: timestamp),
            replacementDecision(from: "active-high", to: "Active High", timestampKey: "added_at", timestamp: timestamp),
        ])
        config.raw["rejected_replacements"] = .array([
            replacementDecision(from: "reject-low", to: "Reject Low", timestampKey: "rejected_at", timestamp: timestamp),
            replacementDecision(from: "reject-high", to: "Reject High", timestampKey: "rejected_at", timestamp: timestamp),
        ])
        let coordinator = makeCoordinator(config: config, paths: paths, clock: { now })

        let sections = coordinator.replacementSections()

        XCTAssertEqual(sections.active.map(\.from), ["active-high", "active-low"])
        XCTAssertEqual(sections.rejected.map(\.from), ["reject-high", "reject-low"])
    }

    func testConflictingApprovedConfigReturnsErrorInsteadOfTrapping() throws {
        let timestamp = ISOTimestamp.now(Date(timeIntervalSince1970: 2_000_000_000))
        var config = makeConfig()
        config.raw["approved_auto_replacements"] = .array([
            replacementDecision(from: "api", to: "API", timestampKey: "approved_at", timestamp: timestamp),
            replacementDecision(from: "api", to: "SDK", timestampKey: "approved_at", timestamp: timestamp),
        ])
        let coordinator = makeCoordinator(config: config, paths: makePaths())

        XCTAssertThrowsError(try coordinator.saveManualReplacements([("other", "Other")])) { error in
            guard let typed = error as? DictionaryCoordinatorError else {
                return XCTFail("Expected DictionaryCoordinatorError, got \(error)")
            }
            guard case .conflictingReplacement = typed else {
                return XCTFail("Expected conflictingReplacement, got \(typed)")
            }
        }
    }

    func testApproveRejectAndRestorePersistPolicyTransitions() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let timestamp = ISOTimestamp.now(now)
        let paths = makePaths()
        try writeReplacementIndex([
            ReplacementPair(from: "Cogni", to: "Cognee", count: 2, lastSeen: timestamp, lastSeenRow: 10),
        ], processedRows: 10, to: paths.correctionsFile)
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths, clock: { now })
        let candidate = try XCTUnwrap(coordinator.replacementSections().candidates.first)

        try coordinator.approveReplacement(candidate)
        XCTAssertEqual(coordinator.replacementSections().active.map(\.from), ["Cogni"])
        XCTAssertEqual(coordinator.snapshot.raw["approved_auto_replacements"]?.arrayValue?.count, 1)

        let active = try XCTUnwrap(coordinator.replacementSections().active.first)
        try coordinator.rejectReplacement(active)
        XCTAssertTrue(coordinator.replacementSections().active.isEmpty)
        XCTAssertEqual(coordinator.replacementSections().rejected.map(\.from), ["Cogni"])
        XCTAssertTrue(coordinator.replacementSections().candidates.isEmpty)

        let rejected = try XCTUnwrap(coordinator.replacementSections().rejected.first)
        try coordinator.restoreReplacement(rejected)
        XCTAssertEqual(coordinator.replacementSections().active.map(\.from), ["Cogni"])
        XCTAssertTrue(coordinator.replacementSections().rejected.isEmpty)
        XCTAssertEqual(Config.load(from: paths.configFile).raw["approved_auto_replacements"]?.arrayValue?.count, 1)
    }

    func testRejectedPairStaysHiddenAfterObservationIndexReturns() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let timestamp = ISOTimestamp.now(now)
        let paths = makePaths()
        let pair = ReplacementPair(from: "Cogni", to: "Cognee", count: 3, lastSeen: timestamp, lastSeenRow: 10)
        try writeReplacementIndex([pair], processedRows: 10, to: paths.correctionsFile)
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths, clock: { now })
        let candidate = try XCTUnwrap(coordinator.replacementSections().candidates.first)
        try coordinator.rejectReplacement(candidate)

        try writeReplacementIndex([pair], processedRows: 10, to: paths.correctionsFile)

        XCTAssertTrue(coordinator.replacementSections().candidates.isEmpty)
        XCTAssertEqual(coordinator.replacementSections().rejected.map(\.from), ["Cogni"])
    }

    func testManualRemovalCreatesTombstoneAndRestoreActivatesPair() throws {
        let paths = makePaths()
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths)
        try coordinator.saveManualReplacements([("ap eye", "API")])
        let manual = try XCTUnwrap(coordinator.replacementSections().active.first)

        try coordinator.removeReplacement(manual)

        XCTAssertTrue(coordinator.replacementSections().active.isEmpty)
        let rejected = try XCTUnwrap(coordinator.replacementSections().rejected.first)
        XCTAssertEqual(rejected.from, "ap eye")
        try coordinator.restoreReplacement(rejected)
        XCTAssertEqual(coordinator.replacementSections().active.map(\.from), ["ap eye"])
    }

    func testManualEditRejectsOldIdentityAndClearsNewRejection() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var config = makeConfig()
        config.raw["rejected_replacements"] = .array([
            replacementDecision(
                from: "ap eye",
                to: "API",
                timestampKey: "rejected_at",
                timestamp: ISOTimestamp.now(now)
            ),
        ])
        let paths = makePaths()
        let coordinator = makeCoordinator(config: config, paths: paths, clock: { now })

        try coordinator.saveManualReplacements([("ap eye", "API")])
        XCTAssertTrue(coordinator.replacementSections().rejected.isEmpty)
        try coordinator.saveManualReplacements([("ap eyes", "APIs")])

        XCTAssertEqual(coordinator.replacementSections().active.map(\.from), ["ap eyes"])
        XCTAssertEqual(coordinator.replacementSections().rejected.map(\.from), ["ap eye"])
    }

    func testManualReplacementConflictsWithApprovedTarget() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var config = makeConfig()
        config.raw["approved_auto_replacements"] = .array([
            replacementDecision(
                from: "api",
                to: "API",
                timestampKey: "approved_at",
                timestamp: ISOTimestamp.now(now)
            ),
        ])
        let coordinator = makeCoordinator(config: config, paths: makePaths(), clock: { now })

        XCTAssertThrowsError(try coordinator.saveManualReplacements([("api", "SDK")])) { error in
            guard case .conflictingReplacement = error as? DictionaryCoordinatorError else {
                return XCTFail("Expected conflictingReplacement, got \(error)")
            }
        }
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

    func testDailyMaintenanceContinuesWhenReplacementPruningFails() async throws {
        let paths = makePaths()
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths)
        try paths.ensureDataDirectory()
        try Data("{not-json".utf8).write(to: paths.correctionsFile)

        coordinator.runDailyMaintenanceIfDue()
        for _ in 0..<50 where coordinator.snapshot.raw["last_metrics_snapshot_ts"]?.stringValue == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotNil(coordinator.snapshot.raw["last_decay_run_ts"]?.stringValue)
        XCTAssertNotNil(coordinator.snapshot.raw["last_metrics_snapshot_ts"]?.stringValue)
    }
}
