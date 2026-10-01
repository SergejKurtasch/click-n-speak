// Regression probes for the 2026-09-07 audit. See the audit plan before importing into a test target.
import CNSCore
import CNSDictionary
import CNSEditors
import CNSTranscription
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
private final class AuditSession: RuntimeSessionCoordinating {
    var isRuntimeIdle = true
    var available = false
    func updateConfig(_ config: Config) {}
    func setRuntimeAvailable(_ available: Bool) { self.available = available }
}

private actor AuditTranscriber: Transcribing {
    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult { .empty }
}

private actor AuditFactory: RuntimeServiceBuilding {
    var count = 0
    var blocked: CheckedContinuation<Void, Never>?
    var pauseNext = false
    func pause() { pauseNext = true }
    func resume() { blocked?.resume(); blocked = nil }
    func prepareTranscriber(config: Config) async throws -> PreparedTranscriber {
        count += 1
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { blocked = $0 }
        }
        return PreparedTranscriber(service: AuditTranscriber(), descriptor: .init(
            backend: config.sttBackend, modelID: "audit-model", kind: .cloud
        ))
    }
    func prepareEditor(config: Config) async throws -> PreparedEditor {
        .init(service: nil, descriptor: .disabled)
    }
}

@MainActor
@Suite("Review audit runtime probes", .serialized)
struct ReviewAuditRuntimeProbes {
    private func configuration() -> Config {
        var config = Config.migrated(JSONObject())
        config.raw["stt_backend"] = .string("gemini")
        config.raw["stt_cloud_model"] = .string("audit-model")
        config.raw["ai_editor_enabled"] = .bool(false)
        config.raw["replacement_policy_initialized"] = .bool(true)
        config.raw["prompt_update_mode"] = .string("disabled")
        return config
    }

    @Test("Revalidation must rebuild an already active credential client")
    func revalidationRebuildsActiveClient() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = AuditFactory()
        let session = AuditSession()
        let config = configuration()
        let coordinator = AppRuntimeCoordinator(initialConfig: config,
            transcriberRouter: TranscriberRouter(), editorRouter: AiEditorRouter(), factory: factory,
            session: session, configURL: directory.appendingPathComponent("config.json"))
        await coordinator.activateInitial(config)
        coordinator.revalidateDesiredConfiguration()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await factory.count == 2)
        await coordinator.shutdown()
    }

    @Test("Prepared candidate must wait if recording started during preparation")
    func preparationCannotCommitIntoRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = AuditFactory()
        let session = AuditSession()
        let router = TranscriberRouter()
        let config = configuration()
        let coordinator = AppRuntimeCoordinator(initialConfig: config,
            transcriberRouter: router, editorRouter: AiEditorRouter(), factory: factory,
            session: session, configURL: directory.appendingPathComponent("config.json"))
        await coordinator.activateInitial(config)
        await factory.pause()
        var changed = config
        changed.raw["stt_backend"] = .string("openai")
        coordinator.requestConfiguration(changed)
        while await factory.count < 2 { await Task.yield() }
        session.isRuntimeIdle = false
        await factory.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(router.currentDescriptorSnapshot.backend == "gemini")
        await coordinator.shutdown()
    }

    @Test("App callback wiring must not discard a dirty term usage update")
    func dirtyUsageSurvivesCoordinatorRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        var config = configuration()
        _ = UserTerms.add(to: &config, lang: "ru", term: "словарь", source: .manual)
        let history = PhraseHistory(fileURL: paths.phraseHistoryFile)
        let dictionary = DictionaryCoordinator(config: config, paths: paths, phraseHistory: history)
        let session = AuditSession()
        let coordinator = AppRuntimeCoordinator(initialConfig: config,
            transcriberRouter: TranscriberRouter(), editorRouter: AiEditorRouter(), factory: AuditFactory(),
            session: session, configURL: paths.configFile)
        coordinator.onConfigActivated = { dictionary.adoptConfiguration($0) }
        dictionary.onSnapshotChanged = { updated, _ in coordinator.adoptPersistedConfiguration(updated) }
        await coordinator.activateInitial(config)
        let record = DatasetRecord(rawWhisper: "словарь", userFinal: "словарь", lang: "ru")
        _ = await dictionary.recordConfirmation(.init(sessionID: 1, datasetRecord: record, finalText: "словарь"))
        try dictionary.flushIfNeeded()
        let disk = Config.load(from: paths.configFile)
        #expect(disk.raw["user_terms"] == dictionary.snapshot.raw["user_terms"])
        await coordinator.shutdown()
    }

    @Test("Startup must preserve malformed original configuration")
    func startupPreservesCorruptConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        try paths.ensureDataDirectory()
        let original = Data("{\"user_terms\": damaged".utf8)
        try original.write(to: paths.configFile)
        let prepared = AppDelegate.prepareDictionaryConfiguration(
            config: Config.load(from: paths.configFile), paths: paths,
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile))
        _ = prepared
        #expect(try Data(contentsOf: paths.configFile) == original)
    }

    @Test("Language change must rebuild the effective initial prompt")
    func languageChangeRebuildsPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = configuration()
        config.raw["primary_language"] = .string("ru")
        config.raw["additional_languages"] = .array([])
        _ = UserTerms.add(to: &config, lang: "ru", term: "словарь", source: .manual)
        _ = UserTerms.add(to: &config, lang: "de", term: "Wörterbuch", source: .manual)
        config.raw["initial_prompt"] = .string(InitialPromptBuilder().build(config: config.raw))
        let session = AuditSession()
        let coordinator = AppRuntimeCoordinator(initialConfig: config,
            transcriberRouter: TranscriberRouter(), editorRouter: AiEditorRouter(), factory: AuditFactory(),
            session: session, configURL: directory.appendingPathComponent("config.json"))
        await coordinator.activateInitial(config)
        config.raw["primary_language"] = .string("de")
        coordinator.requestConfiguration(config)
        let disk = Config.load(from: directory.appendingPathComponent("config.json"))
        #expect(disk.initialPrompt == InitialPromptBuilder().build(config: disk.raw))
        await coordinator.shutdown()
    }
}
