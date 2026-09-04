import CNSCore
import CNSDictionary
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
@Suite("App delegate startup configuration")
struct AppDelegateStartupTests {
    @Test("Dictionary bootstrap snapshot becomes the authoritative startup config")
    func dictionaryBootstrapIsAuthoritative() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        try paths.ensureDataDirectory()

        var index = CorrectionIndex.defaultIndex()
        index.processedRows = 10
        index.replacementPairs["latin"] = [
            ReplacementPair(
                from: "Cogni",
                to: "Cognee",
                count: 3,
                lastSeen: "2099-01-01T00:00:00Z",
                lastSeenRow: 10
            ),
        ]
        try CorrectionAnalyzer.writeIndex(index, to: paths.correctionsFile)

        var config = Config.migrated(JSONObject())
        config.raw["replacement_policy_initialized"] = .bool(false)
        let prepared = AppDelegate.prepareDictionaryConfiguration(
            config: config,
            paths: paths,
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile)
        )

        #expect(prepared.config.raw["replacement_policy_initialized"]?.boolValue == true)
        #expect(prepared.coordinator.snapshot == prepared.config)
        #expect(prepared.config.raw["approved_auto_replacements"]?.arrayValue?.count == 1)
    }
}
