import CNSCore
import CNSDictionary
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
@Suite("App delegate startup configuration")
struct AppDelegateStartupTests {
    @Test("Startup must preserve malformed original configuration")
    func startupPreservesCorruptConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        try paths.ensureDataDirectory()
        let original = Data("{\"user_terms\": damaged".utf8)
        try original.write(to: paths.configFile)
        var recoveryPresented = false
        let app = AppDelegate(paths: paths, recoveryPresenter: { recovery in
            recoveryPresented = true
            #expect(throws: Config.LoadError.self) { try recovery.reload() }
            let competingInstance = SingleInstanceGuard(lockURL: paths.instanceLockFile)
            #expect(!competingInstance.acquire())
            return nil
        })
        app.applicationDidFinishLaunching(Notification(name: Notification.Name("test-launch")))
        #expect(recoveryPresented)
        #expect(try Data(contentsOf: paths.configFile) == original)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(names).isSubset(of: ["config.json", ".instance.lock", "Click-n-speak.log"]))
        #expect(!FileManager.default.fileExists(atPath: paths.phraseHistoryFile.path))
        #expect(!FileManager.default.fileExists(atPath: paths.correctionsFile.path))
        #expect(!FileManager.default.fileExists(atPath: paths.initialPromptFile(lang: "ru").path))
    }

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

@MainActor
@Suite("Configuration recovery")
struct ConfigRecoveryTests {
    @Test("Restoring validates the selected file before creating a backup or changing the original", arguments: ["{bad", "[]", "missing"])
    func invalidBackupDoesNotWrite(contents: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalURL = directory.appendingPathComponent("config.json")
        let backupURL = directory.appendingPathComponent("chosen.json")
        let original = Data([0xff, 0xfe, 0x7b])
        try original.write(to: originalURL)
        if contents != "missing" { try Data(contents.utf8).write(to: backupURL) }
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let recovery = ConfigRecoveryCoordinator(configURL: originalURL)
        #expect(throws: (any Error).self) { try recovery.restore(from: backupURL) }
        #expect(try Data(contentsOf: originalURL) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
    }

    @Test("Explicit restore retains exact original bytes and migrated replacement decisions")
    func validBackupRestoresSafely() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalURL = directory.appendingPathComponent("config.json")
        let backupURL = directory.appendingPathComponent("chosen.json")
        let original = Data([0xff, 0xfe, 0x7b])
        try original.write(to: originalURL)
        let backup = Data("""
        {"schema_version":1,"future":"keep","rejected_replacements":[{"from":"a","to":"b"}]}
        """.utf8)
        try backup.write(to: backupURL)
        let recovery = ConfigRecoveryCoordinator(configURL: originalURL)
        let restored = try recovery.restore(from: backupURL)
        #expect(restored.schemaVersion == 10)
        #expect(restored.raw["future"]?.stringValue == "keep")
        #expect(restored.raw["rejected_replacements"]?.arrayValue?.count == 1)
        #expect(try recovery.reload() == restored)
        #expect(try Data(contentsOf: backupURL) == backup)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.json.recovery-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
    }

    @Test("Failure to preserve original bytes aborts the restore")
    func unreadableOriginalAbortsRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalURL = directory.appendingPathComponent("config.json")
        let backupURL = directory.appendingPathComponent("chosen.json")
        try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: backupURL)
        #expect(throws: (any Error).self) {
            try ConfigRecoveryCoordinator(configURL: originalURL).restore(from: backupURL)
        }
        #expect(try originalURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }
}
