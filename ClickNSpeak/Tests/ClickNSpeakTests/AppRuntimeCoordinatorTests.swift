import CNSCore
import CNSDictionary
import CNSEditors
import CNSSession
import CNSTranscription
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
final class RuntimeSessionDouble: RuntimeSessionCoordinating {
    var isRuntimeIdle = true
    private(set) var runtimeMutationInProgress = false
    private(set) var runtimeAvailable = false
    private(set) var configs: [Config] = []
    private(set) var cancelWarmupCount = 0
    func cancelWarmup() { cancelWarmupCount += 1 }

    func beginRuntimeMutation() -> Bool {
        guard isRuntimeIdle, !runtimeMutationInProgress else { return false }
        runtimeMutationInProgress = true
        return true
    }

    func endRuntimeMutation() {
        runtimeMutationInProgress = false
    }

    func updateConfig(_ config: Config) { configs.append(config) }
    func setRuntimeAvailable(_ available: Bool) { runtimeAvailable = available }
}

actor RuntimeTranscriberDouble: Transcribing {
    let name: String
    let credentialGeneration: Int
    private(set) var stopCount = 0
    private var fileGate: RuntimePreparationGate?

    init(name: String, credentialGeneration: Int = 0) {
        self.name = name
        self.credentialGeneration = credentialGeneration
    }

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        TranscriptionResult(text: name)
    }

    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        await fileGate?.pause()
        return FileTranscriptionResult(text: name, status: .success, segmentCount: 1)
    }

    fileprivate func suspendFile(using gate: RuntimePreparationGate) {
        fileGate = gate
    }

    func stop() async { stopCount += 1 }
}

actor RuntimeEditorDouble: AiEditing {
    nonisolated let isReady = true
    nonisolated let descriptor: AiEditorDescriptor
    let credentialGeneration: Int
    private(set) var stopCount = 0

    init(backend: String, modelID: String, credentialGeneration: Int = 0) {
        self.credentialGeneration = credentialGeneration
        descriptor = AiEditorDescriptor(
            backend: backend,
            modelID: modelID,
            kind: backend == "local" ? .local : .cloud
        )
    }

    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        RefineResult(text: text, status: .unchanged)
    }

    func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        RefineResult(text: text, status: .unchanged)
    }

    func stop() async { stopCount += 1 }
}

final class RuntimeFactoryDouble: RuntimeServiceBuilding, @unchecked Sendable {
    private let lock = NSLock()
    var beforePreparation: (@Sendable (String) async -> Void)?
    var failEditor = false
    var failingBackends = Set<String>()
    var credentialGenerations: [String: Int] = [:]
    var delays: [String: Duration] = [:]
    private(set) var preparedBackends: [String] = []
    private(set) var services: [String: RuntimeTranscriberDouble] = [:]
    private(set) var editorServices: [String: RuntimeEditorDouble] = [:]

    func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber {
        let backend = config.sttBackend
        let credentialGeneration = lock.withLock { credentialGenerations[backend, default: 0] }
        if let before = lock.withLock({ beforePreparation }) { await before(backend) }
        if let delay = lock.withLock({ delays[backend] }) { try await Task.sleep(for: delay) }
        if lock.withLock({ failingBackends.contains(backend) }) {
            throw RuntimePreparationError.credentialMissing(backend: backend)
        }
        let service = RuntimeTranscriberDouble(
            name: backend,
            credentialGeneration: credentialGeneration
        )
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

    func prepareEditor(config: Config, generation: Int) async throws -> PreparedEditor {
        if lock.withLock({ failEditor }) { throw RuntimePreparationError.credentialMissing(backend: "gemini") }
        guard config.aiEditorEnabled else {
            return PreparedEditor(service: nil, descriptor: .disabled)
        }
        let backend = config.aiEditorBackend
        let modelID = backend == "gemini" ? config.geminiModel : config.aiEditorModel
        let credentialGeneration = lock.withLock { credentialGenerations[backend, default: 0] }
        let service = RuntimeEditorDouble(
            backend: backend,
            modelID: modelID,
            credentialGeneration: credentialGeneration
        )
        lock.withLock { editorServices[backend] = service }
        return PreparedEditor(service: service, descriptor: service.descriptor)
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

private actor RuntimeCommitGate {
    private var target: RuntimeCommitStage?
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ stage: RuntimeCommitStage) {
        target = stage
        entered = false
    }

    func reach(_ stage: RuntimeCommitStage) async {
        guard target == stage else { return }
        target = nil
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class RuntimeSessionRecorder: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var callbacks: AudioCallbacks?
    var finalAudio: [Float]?

    var isRecording: Bool { lock.withLock { recording } }

    func start(callbacks: AudioCallbacks) async throws {
        try await start(callbacks: callbacks, settings: RecordingSettings())
    }

    func start(callbacks: AudioCallbacks, settings: RecordingSettings) async throws {
        lock.withLock {
            self.callbacks = callbacks
            recording = true
        }
    }

    func stop() async {
        let completion = lock.withLock { () -> (AudioCallbacks?, [Float]?) in
            recording = false
            let value = (callbacks, finalAudio)
            callbacks = nil
            return value
        }
        completion.0?.onFinal(completion.1)
    }
}

@MainActor
private final class RuntimeSessionPanel: PopupPresenting {
    private(set) var isShowingInteractive = false
    var currentText: String = ""
    private var onCancel: (() -> Void)?

    func showPendingAppend(_ text: String, title: String) {}
    func clearPendingAppend() {}

    func show(title: String) {}
    func updateStatus(_ title: String) {}
    func updateText(_ text: String) {}
    func appendText(_ text: String) {}
    func setDecisionEnabled(_ enabled: Bool) {}
    func showIncompleteWarning(_ message: String) {}
    func hide(delay: TimeInterval) { isShowingInteractive = false }

    func showInteractive(
        text: String,
        title: String,
        toasts: DictionaryToasts,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onAddToDictionary: ((String) -> AddTermResult)?
    ) {
        isShowingInteractive = true
        currentText = text
        self.onCancel = onCancel
    }

    func cancel() {
        let callback = onCancel
        onCancel = nil
        isShowingInteractive = false
        callback?()
    }
}

@MainActor
private struct RuntimeSessionDelivery: TextDelivering {
    func deliver(_ text: String, to pid: pid_t?) async -> TextDeliveryOutcome { .delivered }
}

@MainActor
private struct RuntimeSessionFrontmost: FrontmostAppProviding {
    func frontmostPid() -> pid_t? { 42 }
}

private struct CredentialDouble: CredentialProviding {
    let values: [String: String]

    func password(service: String, account: String) -> String? { values[account] }
}

@MainActor
@Suite("App runtime coordinator", .serialized)
struct AppRuntimeCoordinatorTests {
    private func config(
        backend: String,
        model: String = "model",
        editorBackend: String? = nil
    ) -> Config {
        var raw = JSONObject()
        raw["schema_version"] = .int(9)
        raw["primary_language"] = .string("ru")
        raw["stt_backend"] = .string(backend)
        raw["model_name"] = .string(model)
        raw["stt_cloud_model"] = .string(model)
        raw["ai_editor_enabled"] = .bool(editorBackend != nil)
        raw["ai_editor_backend"] = .string(editorBackend ?? "local")
        raw["ai_editor_model"] = .string("editor-\(editorBackend ?? "local")")
        raw["gemini_model"] = .string("editor-gemini")
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

    private func makeCommitRig(
        initial: Config,
        gate: RuntimeCommitGate
    ) -> (
        AppRuntimeCoordinator, TranscriberRouter, AiEditorRouter,
        RuntimeSessionDouble, RuntimeFactoryDouble, URL
    ) {
        let transcriber = TranscriberRouter()
        let editor = AiEditorRouter()
        let session = RuntimeSessionDouble()
        let factory = RuntimeFactoryDouble()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-commit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = AppRuntimeCoordinator(
            initialConfig: initial,
            transcriberRouter: transcriber,
            editorRouter: editor,
            factory: factory,
            session: session,
            configURL: directory.appendingPathComponent("config.json"),
            commitBarrier: { stage in await gate.reach(stage) }
        )
        return (coordinator, transcriber, editor, session, factory, directory)
    }

    private func settle(_ milliseconds: Int = 100) async {
        try? await Task.sleep(for: .milliseconds(milliseconds * 3))
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

    @Test("Runtime changes request warmup cancellation before waiting for idle")
    func runtimeChangeCancelsWarmupBeforeIdleWait() async {
        let initial = config(backend: "local")
        let (runtime, _, session, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.isRuntimeIdle = false
        runtime.requestConfiguration(initial)
        await settle(30)
        #expect(session.cancelWarmupCount > 0)
        session.isRuntimeIdle = true
        await settle()
        await runtime.shutdown()
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

    @Test("Language change rebuilds the effective prompt before persistence")
    func languageChangeRebuildsPrompt() async throws {
        var initial = config(backend: "local")
        initial.raw["primary_language"] = .string("ru")
        initial.raw["additional_languages"] = .array([])
        _ = UserTerms.add(to: &initial, lang: "ru", term: "словарь", source: .manual)
        _ = UserTerms.add(to: &initial, lang: "de", term: "Wörterbuch", source: .manual)
        initial.raw["initial_prompt"] = .string(InitialPromptBuilder().build(config: initial.raw))
        let (runtime, _, _, _, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        await runtime.activateInitial(initial)

        let desired = LanguageSettings.selectPrimary("de", in: initial)
        runtime.requestConfiguration(desired)
        await settle()

        let disk = try Config.loadValidated(
            from: directory.appendingPathComponent("config.json")
        )
        #expect(disk.primaryLanguage == "de")
        #expect(disk.initialPrompt == InitialPromptBuilder().build(config: disk.raw))
        #expect(disk.initialPrompt.contains("Wörterbuch"))
        #expect(!disk.initialPrompt.contains("словарь"))
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

    @Test("A language change supersedes a stale runtime preparation snapshot")
    func languageChangeDuringPreparation() async throws {
        var initial = usageConfig()
        initial.raw["primary_language"] = .string("ru")
        initial.raw["additional_languages"] = .array([])
        _ = UserTerms.add(to: &initial, lang: "de", term: "Wörterbuch", source: .manual)
        initial.raw["initial_prompt"] = .string(InitialPromptBuilder().build(config: initial.raw))
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

        try dictionary.applyLanguageSettings(LanguageSettings.selectPrimary("de", in: initial))
        await gate.release()
        await settle()

        let disk = try Config.loadValidated(from: directory.appendingPathComponent("config.json"))
        #expect(disk.primaryLanguage == "de")
        #expect(disk.initialPrompt.contains("Wörterbuch"))
        #expect(dictionary.snapshot == disk)
        #expect(runtime.desiredConfiguration.primaryLanguage == "de")
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

    @Test("A rejected editor stage restores both previous runtime services")
    func rejectedEditorStageRollsBackTranscriber() async throws {
        let initial = config(backend: "local", editorBackend: "local")
        let gate = RuntimeCommitGate()
        let (runtime, transcriber, editor, session, factory, directory) = makeCommitRig(
            initial: initial,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        await runtime.activateInitial(initial)
        let previousTranscriber = factory.services["local"]
        let previousEditor = RuntimeEditorDouble(backend: "local", modelID: "external")
        _ = await editor.install(
            previousEditor,
            descriptor: previousEditor.descriptor,
            activationGeneration: 100
        )
        await gate.arm(.betweenRouterInstalls)

        runtime.requestConfiguration(config(backend: "gemini", editorBackend: "gemini"))
        await gate.waitForEntry()
        var dictionary = runtime.desiredConfiguration
        #expect(UserTerms.add(to: &dictionary, lang: "en", term: "RollbackTerm", source: .manual))
        try dictionary.saveAtomically(to: directory.appendingPathComponent("config.json"))
        runtime.updateDictionarySnapshot(dictionary)
        await gate.release()
        await settle()

        #expect(transcriber.currentDescriptorSnapshot.backend == "local")
        #expect(editor.currentDescriptorSnapshot.backend == "local")
        #expect(await previousTranscriber?.stopCount == 0)
        #expect(await previousEditor.stopCount == 0)
        #expect(await factory.services["gemini"]?.stopCount == 1)
        #expect(await factory.editorServices["gemini"]?.stopCount == 1)
        #expect(UserTerms.activeTerms(session.configs.last ?? initial, lang: "en") == ["RollbackTerm"])
        if case let .degraded(active, desired, _, recovery) = runtime.state {
            #expect(active?.transcriber.backend == "local")
            #expect(active?.aiEditor.backend == "local")
            #expect(desired.sttBackend == "gemini")
            #expect(recovery.contains(where: { $0.kind == .retry }))
        } else {
            Issue.record("Expected a rejected router transaction to be recoverable")
        }
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

    @Test("Credential change quarantines a stale partial initial activation")
    func credentialChangeQuarantinesPartialInitialRuntime() async throws {
        let gate = RuntimeCommitGate()
        let initial = config(backend: "gemini", editorBackend: "gemini")
        let (coordinator, transcriber, editor, session, factory, directory) = makeCommitRig(
            initial: initial,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        factory.credentialGenerations["gemini"] = 1
        factory.failEditor = true
        await gate.arm(.betweenRouterInstalls)
        let initialActivation = Task { await coordinator.activateInitial(initial) }
        await gate.waitForEntry()

        let nextPreparation = RuntimePreparationGate()
        factory.failEditor = false
        factory.beforePreparation = { backend in
            if backend == "gemini" { await nextPreparation.pause() }
        }
        factory.credentialGenerations["gemini"] = 2
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await gate.release()
        await nextPreparation.waitForEntry()

        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")
        #expect(editor.currentDescriptorSnapshot == .disabled)
        #expect(!session.runtimeAvailable)

        await nextPreparation.release()
        await initialActivation.value
        await settle(150)
        #expect(session.runtimeAvailable)
        #expect(editor.currentDescriptorSnapshot.backend == "gemini")
        #expect(factory.services["gemini"]?.credentialGeneration == 2)
        await coordinator.shutdown()
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
            #expect(recovery.contains(where: { $0.kind == .openAPIKeys }))
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
        for _ in 0..<20 {
            if router.currentDescriptorSnapshot.backend == "gemini" { break }
            await settle(50)
        }
        #expect(router.currentDescriptorSnapshot.backend == "gemini")
    }

    @Test("A prepared candidate cannot commit after recording starts")
    func preparationCannotCommitIntoRecording() async {
        let local = config(backend: "local")
        let (coordinator, router, session, factory, directory) = makeRig(initial: local)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(local)
        let gate = RuntimePreparationGate()
        factory.beforePreparation = { backend in
            if backend == "gemini" { await gate.pause() }
        }

        coordinator.requestConfiguration(config(backend: "gemini"))
        await gate.waitForEntry()
        session.isRuntimeIdle = false
        await gate.release()
        await settle()

        #expect(router.currentDescriptorSnapshot.backend == "local")
        session.isRuntimeIdle = true
        await settle(150)
        #expect(router.currentDescriptorSnapshot.backend == "gemini")
        await coordinator.shutdown()
    }

    @Test("The real session holds runtime changes across recording, file, and popup activities")
    func realSessionActivitiesHoldRuntime() async {
        let initial = config(backend: "local")
        let transcriber = TranscriberRouter()
        let editor = AiEditorRouter()
        let recorder = RuntimeSessionRecorder()
        let panel = RuntimeSessionPanel()
        let session = SessionController(
            config: initial,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: recorder,
            panel: panel,
            delivery: RuntimeSessionDelivery(),
            frontmost: RuntimeSessionFrontmost(),
            runtimeDescriptorProvider: {
                RuntimeDescriptor(
                    transcriber: transcriber.currentDescriptorSnapshot,
                    aiEditor: editor.currentDescriptorSnapshot
                )
            }
        )
        let factory = RuntimeFactoryDouble()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-real-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppRuntimeCoordinator(
            initialConfig: initial,
            transcriberRouter: transcriber,
            editorRouter: editor,
            factory: factory,
            session: session,
            configURL: directory.appendingPathComponent("config.json")
        )
        await coordinator.activateInitial(initial)
        let base = Date()

        let preparation = RuntimePreparationGate()
        factory.beforePreparation = { backend in
            if backend == "gemini" { await preparation.pause() }
        }
        coordinator.requestConfiguration(config(backend: "gemini"))
        await preparation.waitForEntry()
        session.toggle(now: base)
        await settle()
        await preparation.release()
        await settle()
        #expect(session.isRecording)
        #expect(transcriber.currentDescriptorSnapshot.backend == "local")

        session.toggle(now: base.addingTimeInterval(1))
        for _ in 0..<20 {
            if transcriber.currentDescriptorSnapshot.backend == "gemini" { break }
            await settle(50)
        }
        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")

        let fileGate = RuntimePreparationGate()
        await factory.services["gemini"]?.suspendFile(using: fileGate)
        let file = Task {
            await session.transcribeFile(url: URL(fileURLWithPath: "held.wav"))
        }
        await fileGate.waitForEntry()
        coordinator.requestConfiguration(config(backend: "openai"))
        for _ in 0..<20 {
            if transcriber.currentDescriptorSnapshot.backend == "gemini" { break }
            await settle(50)
        }
        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")
        await fileGate.release()
        _ = await file.value
        for _ in 0..<20 {
            if transcriber.currentDescriptorSnapshot.backend == "openai" { break }
            await settle(50)
        }
        #expect(transcriber.currentDescriptorSnapshot.backend == "openai")

        recorder.finalAudio = [Float](repeating: 0.2, count: 16_000)
        session.toggle(now: base.addingTimeInterval(2))
        await settle()
        session.toggle(now: base.addingTimeInterval(3))
        while !panel.isShowingInteractive { await Task.yield() }
        coordinator.requestConfiguration(initial)
        for _ in 0..<20 {
            if transcriber.currentDescriptorSnapshot.backend == "openai" { break }
            await settle(50)
        }
        #expect(transcriber.currentDescriptorSnapshot.backend == "openai")

        panel.cancel()
        for _ in 0..<20 {
            if transcriber.currentDescriptorSnapshot.backend == "local" { break }
            await settle(50)
        }
        #expect(transcriber.currentDescriptorSnapshot.backend == "local")
        _ = await session.shutdown()
        await coordinator.shutdown()
    }

    @Test("A newer intent waits for a coherent two-router commit")
    func newerIntentWaitsForCoherentCommit() async {
        let gate = RuntimeCommitGate()
        let initial = config(backend: "local", editorBackend: "local")
        let (coordinator, transcriber, editor, session, factory, directory) = makeCommitRig(
            initial: initial,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(initial)
        let nextPreparation = RuntimePreparationGate()
        factory.beforePreparation = { backend in
            if backend == "openai" { await nextPreparation.pause() }
        }
        await gate.arm(.betweenRouterInstalls)

        coordinator.requestConfiguration(config(backend: "gemini", editorBackend: "gemini"))
        await gate.waitForEntry()
        #expect(session.runtimeMutationInProgress)
        #expect(!session.beginRuntimeMutation())
        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")
        #expect(editor.currentDescriptorSnapshot.backend == "local")

        coordinator.requestConfiguration(config(backend: "openai", editorBackend: "local"))
        await gate.release()
        await nextPreparation.waitForEntry()

        #expect(!session.runtimeMutationInProgress)
        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")
        #expect(editor.currentDescriptorSnapshot.backend == "gemini")
        if case let .reconfiguring(active, desired) = coordinator.state {
            #expect(active.transcriber.backend == "gemini")
            #expect(active.aiEditor.backend == "gemini")
            #expect(desired.sttBackend == "openai")
        } else {
            Issue.record("Expected the newer runtime to remain pending")
        }

        await nextPreparation.release()
        for _ in 0..<20 {
            if transcriber.currentDescriptorSnapshot.backend == "openai" { break }
            await settle(50)
        }
        #expect(transcriber.currentDescriptorSnapshot.backend == "openai")
        #expect(editor.currentDescriptorSnapshot.backend == "local")
        await coordinator.shutdown()
    }

    @Test("A credential event during commit quarantines the stale published candidate")
    func credentialChangeDuringCommitQuarantinesPublishedRuntime() async throws {
        let gate = RuntimeCommitGate()
        let initial = config(backend: "local", editorBackend: "local")
        let desired = config(backend: "gemini", editorBackend: "gemini")
        let (coordinator, transcriber, editor, session, factory, directory) = makeCommitRig(
            initial: initial,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(initial)
        factory.credentialGenerations["gemini"] = 1
        await gate.arm(.betweenRouterInstalls)
        coordinator.requestConfiguration(desired)
        await gate.waitForEntry()

        let nextPreparation = RuntimePreparationGate()
        factory.beforePreparation = { backend in
            if backend == "gemini" { await nextPreparation.pause() }
        }
        factory.credentialGenerations["gemini"] = 2
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await gate.release()
        await nextPreparation.waitForEntry()

        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")
        #expect(editor.currentDescriptorSnapshot.backend == "gemini")
        #expect(!session.runtimeAvailable)
        #expect(session.configs.last?.aiEditorEnabled == false)

        await nextPreparation.release()
        await settle(150)
        #expect(session.runtimeAvailable)
        #expect(session.configs.last?.aiEditorEnabled == true)
        #expect(factory.services["gemini"]?.credentialGeneration == 2)
        #expect(factory.editorServices["gemini"]?.credentialGeneration == 2)
        await coordinator.shutdown()
    }

    @Test("A dictionary update during commit is persisted after the coherent runtime")
    func dictionaryUpdateDuringCommitIsAppliedNext() async throws {
        let gate = RuntimeCommitGate()
        let initial = config(backend: "local", editorBackend: "local")
        let (coordinator, transcriber, editor, session, _, directory) = makeCommitRig(
            initial: initial,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(initial)
        await gate.arm(.beforeTranscriberInstall)

        coordinator.requestConfiguration(config(backend: "gemini", editorBackend: "gemini"))
        await gate.waitForEntry()
        var dictionary = coordinator.desiredConfiguration
        #expect(UserTerms.add(to: &dictionary, lang: "en", term: "CommitTerm", source: .manual))
        try dictionary.saveAtomically(to: directory.appendingPathComponent("config.json"))
        coordinator.updateDictionarySnapshot(dictionary)
        await gate.release()
        await settle(150)

        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")
        #expect(editor.currentDescriptorSnapshot.backend == "gemini")
        #expect(UserTerms.activeTerms(try #require(session.configs.last), lang: "en") == ["CommitTerm"])
        let disk = try Config.loadValidated(from: directory.appendingPathComponent("config.json"))
        #expect(UserTerms.activeTerms(disk, lang: "en") == ["CommitTerm"])
        await coordinator.shutdown()
    }

    @Test("A language transaction during runtime commit becomes the next coherent snapshot")
    func languageUpdateDuringRuntimeCommit() async throws {
        var initial = Config.migrated(config(backend: "local", editorBackend: "local").raw)
        initial.raw["replacement_policy_initialized"] = .bool(true)
        initial.raw["primary_language"] = .string("ru")
        initial.raw["additional_languages"] = .array([.string("en")])
        _ = UserTerms.add(to: &initial, lang: "ru", term: "словарь", source: .manual)
        _ = UserTerms.add(to: &initial, lang: "de", term: "Wörterbuch", source: .manual)
        initial.raw["initial_prompt"] = .string(InitialPromptBuilder().build(config: initial.raw))
        let gate = RuntimeCommitGate()
        let (runtime, _, _, session, _, directory) = makeCommitRig(initial: initial, gate: gate)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = dictionary(initial: initial, directory: directory, runtime: runtime)
        await runtime.activateInitial(initial)
        await gate.arm(.betweenRouterInstalls)

        var desired = initial
        desired.raw["stt_backend"] = .string("gemini")
        desired.raw["ai_editor_backend"] = .string("gemini")
        runtime.requestConfiguration(desired)
        await gate.waitForEntry()
        try dictionary.applyLanguageSettings(
            LanguageSettings.selectPrimary("de", in: dictionary.snapshot)
        )
        await gate.release()
        await settle()

        let disk = try Config.loadValidated(
            from: directory.appendingPathComponent("config.json")
        )
        let published = try #require(session.configs.last)
        #expect(disk == dictionary.snapshot)
        #expect(runtime.desiredConfiguration.primaryLanguage == "de")
        #expect(published.primaryLanguage == "de")
        #expect(published.initialPrompt == InitialPromptBuilder().build(config: published.raw))
        #expect(published.initialPrompt.contains("Wörterbuch"))
        await runtime.shutdown()
    }

    @Test("Shutdown waits for a two-router commit before stopping services")
    func shutdownWaitsForCommit() async {
        let gate = RuntimeCommitGate()
        let initial = config(backend: "local", editorBackend: "local")
        let (coordinator, transcriber, editor, session, factory, directory) = makeCommitRig(
            initial: initial,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(initial)
        await gate.arm(.betweenRouterInstalls)
        coordinator.requestConfiguration(config(backend: "gemini", editorBackend: "gemini"))
        await gate.waitForEntry()

        let shutdown = Task { await coordinator.shutdown() }
        while coordinator.state != .stopping { await Task.yield() }
        #expect(session.runtimeMutationInProgress)
        #expect(await factory.services["gemini"]?.stopCount == 0)
        shutdown.cancel()
        await gate.release()
        await shutdown.value

        #expect(!session.runtimeMutationInProgress)
        #expect(transcriber.currentDescriptorSnapshot == .unavailable)
        #expect(editor.currentDescriptorSnapshot == .disabled)
        #expect(await factory.services["gemini"]?.stopCount == 1)
        #expect(await factory.editorServices["gemini"]?.stopCount == 1)
        #expect(coordinator.state == .stopping)
    }

    @Test("Shutdown is terminal while router stop waits for an active use")
    func shutdownRejectsRecoveryDuringRouterDrain() async {
        let initial = config(backend: "local", editorBackend: "local")
        let (coordinator, transcriber, session, factory, directory) = makeRig(initial: initial)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(initial)
        let fileGate = RuntimePreparationGate()
        await factory.services["local"]?.suspendFile(using: fileGate)
        let file = Task {
            await transcriber.transcribeFile(
                FileTranscriptionRequest(url: URL(fileURLWithPath: "held.wav")),
                progress: { _ in }
            )
        }
        await fileGate.waitForEntry()

        let shutdown = Task { await coordinator.shutdown() }
        while session.runtimeAvailable { await Task.yield() }
        var gen = 1
        if case let .degraded(_, _, _, recovery) = coordinator.state, let first = recovery.first { gen = first.generation }
        coordinator.keepPreviousRuntime(generation: gen)
        coordinator.adoptPersistedConfiguration(initial)
        await coordinator.activateInitial(initial)

        #expect(coordinator.state == .stopping)
        #expect(!session.runtimeAvailable)

        await fileGate.release()
        _ = await file.value
        await shutdown.value
        #expect(coordinator.state == .stopping)
        #expect(!session.runtimeAvailable)
        #expect(transcriber.currentDescriptorSnapshot == .unavailable)
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
        coordinator.revalidateDesiredConfiguration(reason: .retry)
        await settle()

        #expect(router.currentDescriptorSnapshot.backend == "gemini")
        #expect(factory.preparedBackends.filter { $0 == "gemini" }.count == 1)
    }

    @Test("Credential revalidation rebuilds an already active cloud client")
    func revalidationRebuildsActiveClient() async throws {
        let active = config(backend: "gemini")
        let (coordinator, _, _, factory, directory) = makeRig(initial: active)
        defer { try? FileManager.default.removeItem(at: directory) }
        factory.credentialGenerations["gemini"] = 1
        await coordinator.activateInitial(active)
        let previous = try #require(factory.services["gemini"])

        factory.credentialGenerations["gemini"] = 2
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await settle()

        let replacement = try #require(factory.services["gemini"])
        #expect(previous !== replacement)
        #expect(replacement.credentialGeneration == 2)
        #expect(factory.preparedBackends.filter { $0 == "gemini" }.count == 2)
        await coordinator.shutdown()
    }

    @Test("Gemini credentials rebuild every selected Gemini component only")
    func geminiCredentialRevalidationTargetsSelectedComponents() async throws {
        let gate = RuntimeCommitGate()
        let localWithGeminiEditor = config(backend: "local", editorBackend: "gemini")
        let (coordinator, _, _, session, factory, directory) = makeCommitRig(
            initial: localWithGeminiEditor,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        factory.credentialGenerations["gemini"] = 1
        await coordinator.activateInitial(localWithGeminiEditor)
        let localSTT = try #require(factory.services["local"])
        let previousEditor = try #require(factory.editorServices["gemini"])

        factory.credentialGenerations["gemini"] = 2
        session.isRuntimeIdle = false
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        #expect(session.runtimeAvailable)
        #expect(session.configs.last?.aiEditorEnabled == false)
        session.isRuntimeIdle = true
        await settle()

        #expect(factory.services["local"] === localSTT)
        let replacementEditor = try #require(factory.editorServices["gemini"])
        #expect(previousEditor !== replacementEditor)
        #expect(replacementEditor.credentialGeneration == 2)
        await coordinator.shutdown()
    }

    @Test("A shared Gemini credential rebuilds both STT and editor")
    func sharedGeminiCredentialRebuildsBothComponents() async throws {
        let gate = RuntimeCommitGate()
        let active = config(backend: "gemini", editorBackend: "gemini")
        let (coordinator, _, _, _, factory, directory) = makeCommitRig(initial: active, gate: gate)
        defer { try? FileManager.default.removeItem(at: directory) }
        factory.credentialGenerations["gemini"] = 1
        await coordinator.activateInitial(active)
        let previousSTT = try #require(factory.services["gemini"])
        let previousEditor = try #require(factory.editorServices["gemini"])

        factory.credentialGenerations["gemini"] = 2
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await settle()

        #expect(factory.services["gemini"] !== previousSTT)
        #expect(factory.editorServices["gemini"] !== previousEditor)
        await coordinator.shutdown()
    }

    @Test("An unrelated OpenAI credential does not rebuild local inference")
    func openAICredentialLeavesLocalInferenceInstalled() async throws {
        let gate = RuntimeCommitGate()
        let active = config(backend: "local", editorBackend: "local")
        let (coordinator, _, _, _, factory, directory) = makeCommitRig(initial: active, gate: gate)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(active)
        let previousSTT = try #require(factory.services["local"])
        let previousEditor = try #require(factory.editorServices["local"])

        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "openai"))
        await settle()

        #expect(factory.services["local"] === previousSTT)
        #expect(factory.editorServices["local"] === previousEditor)
        await coordinator.shutdown()
    }

    @Test("Removing an editor credential disables it without replacing local STT")
    func removedEditorCredentialDisablesOnlyEditor() async throws {
        let gate = RuntimeCommitGate()
        let active = config(backend: "local", editorBackend: "gemini")
        let (coordinator, transcriber, editor, session, factory, directory) = makeCommitRig(
            initial: active,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(active)
        let localSTT = try #require(factory.services["local"])
        let previousEditor = try #require(factory.editorServices["gemini"])
        factory.failEditor = true

        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await settle()

        #expect(transcriber.currentDescriptorSnapshot.backend == "local")
        #expect(factory.services["local"] === localSTT)
        #expect(editor.currentDescriptorSnapshot == .disabled)
        #expect(await previousEditor.stopCount == 1)
        #expect(session.runtimeAvailable)
        if case let .degraded(runtime, _, _, recovery) = coordinator.state {
            #expect(runtime?.transcriber.backend == "local")
            #expect(runtime?.aiEditor == .disabled)
            #expect(recovery.contains(where: { $0.kind == .openAPIKeys }))
        } else {
            Issue.record("Expected credential recovery state")
        }
        await coordinator.shutdown()
    }

    @Test("Removing a shared cloud credential disables both Gemini components")
    func removedSharedCredentialDisablesCloudRuntime() async throws {
        let gate = RuntimeCommitGate()
        let active = config(backend: "gemini", editorBackend: "gemini")
        let (coordinator, transcriber, editor, session, factory, directory) = makeCommitRig(
            initial: active,
            gate: gate
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(active)
        let previousSTT = try #require(factory.services["gemini"])
        let previousEditor = try #require(factory.editorServices["gemini"])
        factory.failingBackends.insert("gemini")
        factory.failEditor = true

        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await settle()

        #expect(transcriber.currentDescriptorSnapshot == .unavailable)
        #expect(editor.currentDescriptorSnapshot == .disabled)
        #expect(await previousSTT.stopCount == 1)
        #expect(await previousEditor.stopCount == 1)
        #expect(!session.runtimeAvailable)
        if case let .degraded(runtime, _, _, recovery) = coordinator.state {
            #expect(runtime?.transcriber == .unavailable)
            #expect(runtime?.aiEditor == .disabled)
            #expect(recovery.contains(where: { $0.kind == .openAPIKeys }))
        } else {
            Issue.record("Expected credential recovery state")
        }

        coordinator.revalidateDesiredConfiguration(reason: .retry)
        await settle()
        if case let .degraded(_, _, _, recovery) = coordinator.state {
            #expect(recovery.contains(where: { $0.kind == .openAPIKeys }))
        } else {
            Issue.record("Expected credential recovery state after retry")
        }
        var gen = 1
        if case let .degraded(_, _, _, recovery) = coordinator.state, let first = recovery.first { gen = first.generation }
        coordinator.keepPreviousRuntime(generation: gen)
        #expect(!session.runtimeAvailable)
        if case .degraded = coordinator.state {
            // The stopped credential client cannot be restored as a previous runtime.
        } else {
            Issue.record("Expected unavailable runtime to remain degraded")
        }

        factory.failingBackends.remove("gemini")
        factory.failEditor = false
        factory.credentialGenerations["gemini"] = 2
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await settle()
        #expect(transcriber.currentDescriptorSnapshot.backend == "gemini")
        #expect(editor.currentDescriptorSnapshot.backend == "gemini")
        #expect(session.runtimeAvailable)
        await coordinator.shutdown()
    }

    @Test("Credential revalidation waits for recording and newest generation wins")
    func credentialRevalidationWaitsForIdleAndSupersedesOlderGeneration() async throws {
        let active = config(backend: "gemini")
        let (coordinator, _, session, factory, directory) = makeRig(initial: active)
        defer { try? FileManager.default.removeItem(at: directory) }
        factory.credentialGenerations["gemini"] = 1
        await coordinator.activateInitial(active)
        let original = try #require(factory.services["gemini"])
        session.isRuntimeIdle = false
        factory.credentialGenerations["gemini"] = 2
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        #expect(!session.runtimeAvailable)
        await settle()
        #expect(factory.services["gemini"] === original)

        session.isRuntimeIdle = true
        factory.delays["gemini"] = .milliseconds(200)
        await settle(60)
        factory.credentialGenerations["gemini"] = 3
        coordinator.revalidateDesiredConfiguration(reason: .credentials(provider: "gemini"))
        await settle(350)

        let replacement = try #require(factory.services["gemini"])
        #expect(replacement !== original)
        #expect(replacement.credentialGeneration == 3)
        #expect(factory.preparedBackends.filter { $0 == "gemini" }.count == 2)
        #expect(session.runtimeAvailable)
        await coordinator.shutdown()
    }

    @Test("Model revalidation rebuilds only the selected local model")
    func modelRevalidationTargetsSelectedLocalComponent() async throws {
        let gate = RuntimeCommitGate()
        let active = config(backend: "local", model: "stt-model", editorBackend: "local")
        let (coordinator, _, _, _, factory, directory) = makeCommitRig(initial: active, gate: gate)
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.activateInitial(active)
        let previousSTT = try #require(factory.services["local"])
        let previousEditor = try #require(factory.editorServices["local"])

        coordinator.revalidateDesiredConfiguration(reason: .model(id: "editor-local"))
        await settle()
        let replacementEditor = try #require(factory.editorServices["local"])
        #expect(factory.services["local"] === previousSTT)
        #expect(replacementEditor !== previousEditor)

        coordinator.revalidateDesiredConfiguration(reason: .model(id: "stt-model"))
        await settle()
        #expect(factory.services["local"] !== previousSTT)
        #expect(factory.editorServices["local"] === replacementEditor)
        await coordinator.shutdown()
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

        var gen = 1
        if case let .degraded(_, _, _, recovery) = coordinator.state, let first = recovery.first { gen = first.generation }
        coordinator.keepPreviousRuntime(generation: gen)

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
            _ = try await factory.prepareTranscriber(config: local, generation: 1)
        }

        let model = ModelRegistry.whisperModel(id: ModelRegistry.defaultWhisperModelID)!
        try Data([0, 1, 2]).write(to: paths.modelFile(for: model))
        await #expect(throws: RuntimePreparationError.modelCorrupted(modelID: model.id)) {
            _ = try await factory.prepareTranscriber(config: local, generation: 1)
        }
    }

    @Test("Missing cloud credential never creates a fallback service")
    func missingCredential() async {
        let (paths, directory) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = RuntimeServiceFactory(paths: paths, credentials: CredentialDouble(values: [:]))

        await #expect(throws: RuntimePreparationError.credentialMissing(backend: "gemini")) {
            _ = try await factory.prepareTranscriber(config: config(backend: "gemini", model: "flash"), generation: 1)
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
            config: config(backend: "openai", model: "gpt-4o-mini-transcribe"), generation: 1
        )

        #expect(prepared.descriptor.backend == "openai")
        #expect(!(prepared.service is StubTranscriber))
    }
}
