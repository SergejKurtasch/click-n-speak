import CNSCore
import CNSDictionary
import CNSEditors
import CNSTranscription
import CNSUI
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
@Suite("App delegate startup configuration")
struct AppDelegateStartupTests {
    @Test("Production dictionary publications preserve the pending backend in the menu")
    func dictionaryPublicationPreservesPendingMenuSelection() async throws {
        let (app, runtime, session, dictionary, menu, paths) = makeConfigurationBridge()
        defer {
            withExtendedLifetime(app) {}
            try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent())
        }
        await runtime.activateInitial(dictionary.snapshot)
        session.isRuntimeIdle = false
        var desired = dictionary.snapshot
        desired.raw["stt_backend"] = .string("gemini")
        desired.raw["stt_cloud_model"] = .string("pending-model")
        menu.onConfigChanged?(desired)

        #expect(dictionary.addManualTerm("NewTerm", language: "en"))

        #expect(!menu.state.history.isLoading)
        #expect(menu.state.history.totalCount == 0)
        #expect(menu.state.runtime.phase == .reconfiguring)
        #expect(menu.state.runtime.desiredSTTBackend == "gemini")
        #expect(menu.state.runtime.desiredSTTModel == "pending-model")
        #expect(menu.state.config.sttBackend == "gemini")
        #expect(UserTerms.activeTerms(menu.state.config, lang: "en") == ["NewTerm"])
        #expect(runtime.desiredConfiguration.sttBackend == "gemini")
        #expect(session.configs.last?.sttBackend == "local")
        #expect(try Config.loadValidated(from: paths.configFile) == dictionary.snapshot)
        #expect(try Config.loadValidated(from: paths.configFile).sttBackend == "local")
        await runtime.shutdown()
    }

    @Test("Production history-only publications refresh history without adopting their config payload")
    func historyPublicationOnlyRefreshesMenuHistory() async throws {
        let (app, runtime, session, dictionary, menu, paths) = makeConfigurationBridge()
        defer {
            withExtendedLifetime(app) {}
            try? FileManager.default.removeItem(at: paths.configFile.deletingLastPathComponent())
        }
        await runtime.activateInitial(dictionary.snapshot)
        session.isRuntimeIdle = false
        var desired = dictionary.snapshot
        desired.raw["stt_backend"] = .string("gemini")
        menu.onConfigChanged?(desired)
        let menuBefore = menu.state.config
        let activeBefore = session.configs.last
        let diskBefore = try Data(contentsOf: paths.configFile)
        let record = DatasetRecord(rawWhisper: "history only", userFinal: "history only", lang: "en")
        _ = await dictionary.recordConfirmation(.init(sessionID: 1, datasetRecord: record, finalText: "history only"))
        var obsoletePayload = dictionary.snapshot
        obsoletePayload.raw["stt_backend"] = .string("openai")
        obsoletePayload.raw["primary_language"] = .string("de")
        dictionary.onSnapshotChanged?(obsoletePayload, .history)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while menu.state.history.isLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!menu.state.history.isLoading)
        #expect(menu.state.history.totalCount == 1)
        #expect(menu.state.history.rows.first?.text == "history only")
        #expect(menu.state.config == menuBefore)
        #expect(menu.state.runtime.desiredSTTBackend == "gemini")
        #expect(menu.state.runtime.phase == .reconfiguring)
        #expect(runtime.desiredConfiguration == menuBefore)
        #expect(session.configs.last == activeBefore)
        #expect(try Data(contentsOf: paths.configFile) == diskBefore)
        await runtime.shutdown()
    }

    private func makeConfigurationBridge() -> (
        AppDelegate, AppRuntimeCoordinator, RuntimeSessionDouble,
        DictionaryCoordinator, MenuBarController, Paths
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        var initial = Config.migrated(JSONObject())
        initial.raw["primary_language"] = .string("en")
        initial.raw["ai_editor_enabled"] = .bool(false)
        initial.raw["prompt_update_mode"] = .string("disabled")
        initial.raw["replacement_policy_initialized"] = .bool(true)
        let history = PhraseHistory(fileURL: paths.phraseHistoryFile)
        let dictionary = DictionaryCoordinator(config: initial, paths: paths, phraseHistory: history)
        let session = RuntimeSessionDouble()
        let runtime = AppRuntimeCoordinator(initialConfig: dictionary.snapshot,
            transcriberRouter: TranscriberRouter(), editorRouter: AiEditorRouter(),
            factory: RuntimeFactoryDouble(), session: session, configURL: paths.configFile)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = AppResources(localesDirectory: root.appendingPathComponent("locales"),
            iconsDirectory: root.appendingPathComponent("assets/icons"))
        let menu = MenuBarController(config: initial,
            i18n: I18n.load("en", localesDirectory: resources.localesDirectory), resources: resources,
            paths: paths, phraseHistory: history, dictionaryCoordinator: dictionary, installStatusItem: false)
        let app = AppDelegate(paths: paths)
        app.connectConfiguration(dictionary: dictionary, runtime: runtime, menu: menu)
        return (app, runtime, session, dictionary, menu, paths)
    }

    @Test("Startup must preserve malformed original configuration")
    func startupPreservesCorruptConfig() async throws {
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        while names.contains(where: { $0.hasPrefix("Click-n-speak.log.sb-") })
                && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
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
