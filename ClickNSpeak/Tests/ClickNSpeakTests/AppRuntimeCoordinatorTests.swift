import CNSCore
import CNSDictionary
import CNSEditors
import CNSTranscription
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
private final class RuntimeSessionDouble: RuntimeSessionCoordinating {
    var isRuntimeIdle = true
    private(set) var runtimeAvailable = false
    private(set) var configs: [Config] = []

    func updateConfig(_ config: Config) { configs.append(config) }
    func setRuntimeAvailable(_ available: Bool) { runtimeAvailable = available }
}

private actor RuntimeTranscriberDouble: Transcribing {
    let name: String
    private(set) var stopCount = 0

    init(name: String) { self.name = name }

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        TranscriptionResult(text: name)
    }

    func stop() async { stopCount += 1 }
}

private final class RuntimeFactoryDouble: RuntimeServiceBuilding, @unchecked Sendable {
    private let lock = NSLock()
    var beforePreparation: (@Sendable (String) async -> Void)?
    var failEditor = false
    var failingBackends = Set<String>()
    var delays: [String: Duration] = [:]
    private(set) var preparedBackends: [String] = []
    private(set) var services: [String: RuntimeTranscriberDouble] = [:]

    func prepareTranscriber(config: Config) async throws -> PreparedTranscriber {
        let backend = config.sttBackend
        if let before = lock.withLock({ beforePreparation }) { await before(backend) }
        if let delay = lock.withLock({ delays[backend] }) { try await Task.sleep(for: delay) }
        if lock.withLock({ failingBackends.contains(backend) }) {
            throw RuntimePreparationError.credentialMissing(backend: backend)
        }
        let service = RuntimeTranscriberDouble(name: backend)
        lock.withLock {
            preparedBackends.append(backend)
            services[backend] = service
        }
        let model = config.sttBackend == "local"
            ? config.sttModelName
            : (config.raw["stt_cloud_model"]?.stringValue ?? "cloud")
        return PreparedTranscriber(
            service: service,
            descriptor: TranscriberDescriptor(
                backend: backend,
                modelID: model,
                kind: backend == "local" ? .local : .cloud
            )
        )
    }

    func prepareEditor(config: Config) async throws -> PreparedEditor {
        if lock.withLock({ failEditor }) { throw RuntimePreparationError.credentialMissing(backend: "gemini") }
        return PreparedEditor(service: nil, descriptor: .disabled)
    }
}

private actor RuntimePreparationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async {
        while !entered { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct CredentialDouble: CredentialProviding {
    let values: [String: String]

    func password(service: String, account: String) -> String? { values[account] }
}

@MainActor
@Suite("App runtime coordinator", .serialized)
struct AppRuntimeCoordinatorTests {
    private func config(backend: String, model: String = "model") -> Config {
        var raw = JSONObject()
        raw["schema_version"] = .int(9)
        raw["primary_language"] = .string("ru")
        raw["stt_backend"] = .string(backend)
        raw["model_name"] = .string(model)
        raw["stt_cloud_model"] = .string(model)
        raw["ai_editor_enabled"] = .bool(false)
        return Config(raw: raw)
    }

    private func makeRig(initial: Config) -> (
        AppRuntimeCoordinator, TranscriberRouter, RuntimeSessionDouble, RuntimeFactoryDouble, URL
    ) {
        let router = TranscriberRouter()
        let editor = AiEditorRouter()
        let session = RuntimeSessionDouble()
        let factory = RuntimeFactoryDouble()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-coordinator-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let coordinator = AppRuntimeCoordinator(
            initialConfig: initial,
            transcriberRouter: router,
            editorRouter: editor,
            factory: factory,
            session: session,
            configURL: url
        )
        return (coordinator, router, session, factory, directory)
    }

    private func settle(_ milliseconds: Int = 100) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func dictionary(initial: Config, directory: URL, runtime: AppRuntimeCoordinator) -> DictionaryCoordinator {
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        let dictionary = DictionaryCoordinator(config: initial, paths: paths,
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile))
        runtime.onConfigActivated = { dictionary.adoptConfiguration($0) }
        dictionary.onSnapshotChanged = { updated, invalidations in
            if invalidations.contains(.config) { runtime.updateDictionarySnapshot(updated) }
        }
        return dictionary
    }

    private func usageConfig() -> Config {
        var initial = Config.migrated(config(backend: "local").raw)
        initial.raw["replacement_policy_initialized"] = .bool(true)
        initial.raw["prompt_update_mode"] = .string("disabled")
        initial.raw["future_extension"] = .string("preserve")
        var term = JSONObject()
        term["term"] = .string("словарь")
        term["source"] = .string("auto")
        term["use_count"] = .int(0)
        term["added_at"] = .string("2000-01-01T00:00:00Z")
        term["last_seen"] = .string("2000-01-01T00:00:00Z")
        term["inactive"] = .bool(true)
        initial.raw["user_terms"] = .object(JSONObject([("ru", .array([.object(term)]))]))
        return initial
    }

    private func confirm(_ dictionary: DictionaryCoordinator, id: Int = 1) async {
        let record = DatasetRecord(rawWhisper: "словарь", userFinal: "словарь", lang: "ru")
        _ = await dictionary.recordConfirmation(.init(sessionID: id, datasetRecord: record,
            finalText: "словарь", date: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    @Test("App callback wiring retains dirty usage until an explicit confirmation then flush")
    func dirtyUsageSurvivesCoordinatorRoundTrip() async throws {
        let initial = usageConfig()
        let (runtime, _, _, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        await confirm(dictionary)
        let term = dictionary.snapshot.raw["user_terms"]?.objectValue?["ru"]?.arrayValue?.first?.objectValue
        #expect(term?["use_count"]?.intValue == 1)
        #expect(term?["last_seen"]?.stringValue == "2033-05-18T03:33:20.000000+00:00")
        #expect(term?["inactive"]?.boolValue != true)
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json")) != dictionary.snapshot)
        try dictionary.flushIfNeeded()
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json")) == dictionary.snapshot)
        await runtime.shutdown()
    }

    @Test("History and usage publication preserve a backend waiting for idle")
    func dictionaryPublicationPreservesPendingBackend() async throws {
        let initial = usageConfig()
        let (runtime, router, session, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        session.isRuntimeIdle = false
        var desired = initial
        desired.raw["stt_backend"] = .string("gemini")
        runtime.requestConfiguration(desired)
        await confirm(dictionary)
        if case let .reconfiguring(_, selection) = runtime.state {
            #expect(selection.sttBackend == "gemini")
        } else { Issue.record("Dictionary publication cancelled pending selection") }
        session.isRuntimeIdle = true
        await settle(150)
        #expect(router.currentDescriptorSnapshot.backend == "gemini")
        #expect(dictionary.snapshot.sttBackend == "gemini")
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json")) == dictionary.snapshot)
        await runtime.shutdown()
    }

    @Test("A stale menu setting merges the latest dictionary term")
    func staleMenuSettingPreservesLatestTerm() async throws {
        let initial = usageConfig()
        let (runtime, _, _, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        #expect(dictionary.addManualTerm("SwiftUI", language: "en"))
        var menuConfig = initial
        menuConfig.raw["silence_duration"] = .double(2)
        runtime.requestConfiguration(menuConfig)
        #expect(UserTerms.activeTerms(dictionary.snapshot, lang: "en") == ["SwiftUI"])
        #expect(dictionary.snapshot.raw["silence_duration"]?.doubleValue == 2)
        #expect(dictionary.snapshot.raw["future_extension"]?.stringValue == "preserve")
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json")) == dictionary.snapshot)
        await runtime.shutdown()
    }

    @Test("Dictionary changes during preparation are included in the runtime write")
    func dictionaryChangeDuringPreparation() async throws {
        let initial = usageConfig()
        let (runtime, _, _, factory, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        let gate = RuntimePreparationGate()
        factory.beforePreparation = { backend in if backend == "gemini" { await gate.pause() } }
        var desired = initial
        desired.raw["stt_backend"] = .string("gemini")
        runtime.requestConfiguration(desired)
        await gate.waitForEntry()
        await confirm(dictionary)
        await gate.release()
        await settle()
        let disk = try Config.loadValidated(from: directory.appendingPathComponent("config.json"))
        #expect(disk.sttBackend == "gemini")
        #expect(disk.raw["user_terms"]?.objectValue?["ru"]?.arrayValue?.first?.objectValue?["use_count"]?.intValue == 1)
        #expect(dictionary.snapshot == disk)
        await runtime.shutdown()
    }

    @Test("A persistence acknowledgement precedes router awaits and cannot overwrite a newer term")
    func dictionaryEditAtPersistenceBoundarySurvivesActivation() async throws {
        let initial = usageConfig()
        let (runtime, router, session, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        var acknowledgements = 0
        runtime.onConfigActivated = { saved in
            dictionary.adoptConfiguration(saved)
            acknowledgements += 1
            #expect(router.currentDescriptorSnapshot.backend == "local")
            if acknowledgements == 1 { #expect(dictionary.addManualTerm("DuringInstall", language: "en")) }
        }
        var desired = initial
        desired.raw["stt_backend"] = .string("gemini")
        runtime.requestConfiguration(desired)
        await settle()
        #expect(acknowledgements == 1)
        #expect(router.currentDescriptorSnapshot.backend == "gemini")
        #expect(UserTerms.activeTerms(try #require(session.configs.last), lang: "en") == ["DuringInstall"])
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json")) == dictionary.snapshot)
        await runtime.shutdown()
    }

    @Test("Rejected router installation still acknowledges the bytes successfully written")
    func persistedAcknowledgementSurvivesRejectedInstallation() async throws {
        let initial = usageConfig()
        let (runtime, router, _, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        _ = await router.install(RuntimeTranscriberDouble(name: "local"),
            descriptor: router.currentDescriptorSnapshot, activationGeneration: 100)
        var desired = initial
        desired.raw["stt_backend"] = .string("gemini")
        runtime.requestConfiguration(desired)
        await settle()
        #expect(router.currentDescriptorSnapshot.backend == "local")
        #expect(dictionary.snapshot.sttBackend == "gemini")
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json")) == dictionary.snapshot)
        await runtime.shutdown()
    }

    @Test("Partial initial activation does not acknowledge an unwritten configuration")
    func partialInitialActivationDoesNotAcknowledgeDirtyUsage() async throws {
        var initial = usageConfig()
        initial.raw["ai_editor_enabled"] = .bool(true)
        let (runtime, _, _, factory, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        try initial.saveAtomically(to: directory.appendingPathComponent("config.json"))
        await confirm(dictionary)
        factory.failEditor = true
        var acknowledgements = 0
        runtime.onConfigActivated = { dictionary.adoptConfiguration($0); acknowledgements += 1 }
        await runtime.activateInitial(initial)
        #expect(acknowledgements == 0)
        try dictionary.flushIfNeeded()
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json"))
            .raw["user_terms"]?.objectValue?["ru"]?.arrayValue?.first?.objectValue?["use_count"]?.intValue == 1)
        await runtime.shutdown()
    }

    @Test("Failed dirty flush retains ownership and retry writes the latest confirmation")
    func failedDictionaryFlushRetriesLatestSnapshot() async throws {
        let initial = usageConfig()
        let (runtime, _, _, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        await confirm(dictionary)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try dictionary.flushIfNeeded() }
        await confirm(dictionary, id: 2)
        try FileManager.default.removeItem(at: url)
        try dictionary.flushIfNeeded()
        let disk = try Config.loadValidated(from: url)
        #expect(disk == dictionary.snapshot)
        #expect(disk.raw["user_terms"]?.objectValue?["ru"]?.arrayValue?.first?.objectValue?["use_count"]?.intValue == 2)
        await runtime.shutdown()
    }

    @Test("Explicit persisted reload replaces dictionary ownership even with a changed backend")
    func externallyPersistedReloadAdoptsFullConfiguration() async throws {
        let initial = usageConfig()
        let (runtime, _, _, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        await confirm(dictionary)
        var external = initial
        external.raw["stt_backend"] = .string("gemini")
        external.raw["user_terms"] = .object(JSONObject())
        external.raw["future_extension"] = .string("external")
        try external.saveAtomically(to: directory.appendingPathComponent("config.json"))
        runtime.adoptPersistedConfiguration(external)
        try dictionary.flushIfNeeded()
        #expect(dictionary.snapshot == external)
        await settle()
        #expect(try Config.loadValidated(from: directory.appendingPathComponent("config.json")) == external)
        await runtime.shutdown()
    }

    @Test("Local to Gemini to OpenAI to local activation updates the router")
    func activationSequence() async {
        let local = config(backend: "local", model: "turbo")
        let (coordinator, router, session, _, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }

        await coordinator.activateInitial(local)
        #expect(router.currentDescriptorSnapshot.backend == "local")
        #expect(session.runtimeAvailable)

        coordinator.requestConfiguration(config(backend: "gemini", model: "flash"))
        await settle()
        #expect(router.currentDescriptorSnapshot.backend == "gemini")

        coordinator.requestConfiguration(config(backend: "openai", model: "gpt"))
        await settle()
        #expect(router.currentDescriptorSnapshot.backend == "openai")

        coordinator.requestConfiguration(local)
        await settle()
        #expect(router.currentDescriptorSnapshot.backend == "local")
    }

    @Test("Failed candidate preserves the previous active runtime")
    func rollbackOnFailure() async {
        let local = config(backend: "local")
        let (coordinator, router, session, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        factory.failingBackends.insert("gemini")

        coordinator.requestConfiguration(config(backend: "gemini"))
        await settle()

        #expect(router.currentDescriptorSnapshot.backend == "local")
        #expect(session.runtimeAvailable)
        if case let .degraded(active, _, _, recovery) = coordinator.state {
            #expect(active?.transcriber.backend == "local")
            #expect(recovery.contains(.openAPIKeys))
        } else {
            Issue.record("Expected degraded state")
        }
    }

    @Test("A config write failure leaves the previous runtime installed")
    func rollbackOnPersistenceFailure() async throws {
        let local = config(backend: "local")
        let (coordinator, router, session, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        let configURL = directory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)

        coordinator.requestConfiguration(config(backend: "gemini"))
        await settle()

        #expect(router.currentDescriptorSnapshot.backend == "local")
        #expect(session.runtimeAvailable)
        #expect(await factory.services["gemini"]?.stopCount == 1)
        if case let .degraded(active, _, _, _) = coordinator.state {
            #expect(active?.transcriber.backend == "local")
        } else {
            Issue.record("Expected degraded state")
        }
    }

    @Test("Selection during recording stays pending until idle")
    func waitsForIdle() async {
        let local = config(backend: "local")
        let (coordinator, router, session, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        session.isRuntimeIdle = false

        coordinator.requestConfiguration(config(backend: "gemini"))
        await settle()
        #expect(router.currentDescriptorSnapshot.backend == "local")
        #expect(!factory.preparedBackends.contains("gemini"))

        session.isRuntimeIdle = true
        await settle()
        #expect(router.currentDescriptorSnapshot.backend == "gemini")
    }

    @Test("A rapid newer selection supersedes an obsolete candidate")
    func newestGenerationWins() async {
        let local = config(backend: "local")
        let (coordinator, router, _, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        factory.delays["gemini"] = .milliseconds(250)

        coordinator.requestConfiguration(config(backend: "gemini"))
        await settle(20)
        coordinator.requestConfiguration(config(backend: "openai"))
        await settle(350)

        #expect(router.currentDescriptorSnapshot.backend == "openai")
    }

    @Test("Prerequisite update revalidates and activates the pending backend once")
    func revalidationActivatesPendingBackend() async {
        let local = config(backend: "local")
        let (coordinator, router, _, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        factory.failingBackends.insert("gemini")
        coordinator.requestConfiguration(config(backend: "gemini"))
        await settle()
        #expect(router.currentDescriptorSnapshot.backend == "local")

        factory.failingBackends.remove("gemini")
        coordinator.revalidateDesiredConfiguration()
        await settle()

        #expect(router.currentDescriptorSnapshot.backend == "gemini")
        #expect(factory.preparedBackends.filter { $0 == "gemini" }.count == 1)
    }

    @Test("Keep previous runtime restores its persisted configuration")
    func keepPreviousRuntime() async {
        let local = config(backend: "local")
        let (coordinator, router, session, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        factory.failingBackends.insert("gemini")
        coordinator.requestConfiguration(config(backend: "gemini"))
        await settle()

        coordinator.keepPreviousRuntime()

        #expect(router.currentDescriptorSnapshot.backend == "local")
        #expect(session.runtimeAvailable)
        #expect(Config.load(from: directory.appendingPathComponent("config.json")).sttBackend == "local")
        if case let .ready(active) = coordinator.state {
            #expect(active.transcriber.backend == "local")
        } else {
            Issue.record("Expected ready state")
        }
    }

    @Test("Shutdown disables recording and stops the active service once")
    func shutdown() async {
        let local = config(backend: "local")
        let (coordinator, _, session, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        let service = factory.services["local"]

        await coordinator.shutdown()

        #expect(session.runtimeAvailable == false)
        #expect(await service?.stopCount == 1)
        #expect(coordinator.state == .stopping)
    }
}

@Suite("Production runtime service factory")
struct RuntimeServiceFactoryTests {
    private func paths() -> (Paths, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-factory-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        try? paths.ensureModelsDirectory()
        return (paths, directory)
    }

    private func config(backend: String, model: String) -> Config {
        var raw = JSONObject()
        raw["schema_version"] = .int(9)
        raw["primary_language"] = .string("ru")
        raw["stt_backend"] = .string(backend)
        raw["model_name"] = .string(model)
        raw["stt_cloud_model"] = .string(model)
        raw["ai_editor_enabled"] = .bool(false)
        return Config(raw: raw)
    }

    @Test("Missing and partial local models are typed preparation failures")
    func validatesLocalModel() async throws {
        let (paths, directory) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = RuntimeServiceFactory(paths: paths, credentials: CredentialDouble(values: [:]))
        let local = config(backend: "local", model: ModelRegistry.defaultWhisperModelID)

        await #expect(throws: RuntimePreparationError.modelMissing(modelID: ModelRegistry.defaultWhisperModelID)) {
            _ = try await factory.prepareTranscriber(config: local)
        }

        let model = ModelRegistry.whisperModel(id: ModelRegistry.defaultWhisperModelID)!
        try Data([0, 1, 2]).write(to: paths.modelFile(for: model))
        await #expect(throws: RuntimePreparationError.modelCorrupted(modelID: model.id)) {
            _ = try await factory.prepareTranscriber(config: local)
        }
    }

    @Test("Missing cloud credential never creates a fallback service")
    func missingCredential() async {
        let (paths, directory) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = RuntimeServiceFactory(paths: paths, credentials: CredentialDouble(values: [:]))

        await #expect(throws: RuntimePreparationError.credentialMissing(backend: "gemini")) {
            _ = try await factory.prepareTranscriber(config: config(backend: "gemini", model: "flash"))
        }
    }

    @Test("A production cloud candidate is guarded and is never StubTranscriber")
    func productionFactoryHasNoStubFallback() async throws {
        let (paths, directory) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = RuntimeServiceFactory(
            paths: paths,
            credentials: CredentialDouble(values: ["openai_api_key": "test-key"])
        )

        let prepared = try await factory.prepareTranscriber(
            config: config(backend: "openai", model: "gpt-4o-mini-transcribe")
        )

        #expect(prepared.descriptor.backend == "openai")
        #expect(!(prepared.service is StubTranscriber))
    }
}
