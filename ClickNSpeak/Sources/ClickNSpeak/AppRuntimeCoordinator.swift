import CNSCore
import CNSEditors
import CNSSession
import CNSTranscription
import Foundation

struct RuntimeSelection: Sendable, Equatable {
    let sttBackend: String
    let sttModelID: String
    let editorEnabled: Bool
    let editorBackend: String
    let editorModelID: String?

    init(config: Config) {
        sttBackend = config.sttBackend
        sttModelID = config.sttBackend == "local"
            ? config.sttModelName
            : (config.raw["stt_cloud_model"]?.stringValue ?? "")
        editorEnabled = config.aiEditorEnabled
        editorBackend = config.aiEditorEnabled ? config.aiEditorBackend : "disabled"
        editorModelID = config.aiEditorEnabled
            ? (config.aiEditorBackend == "gemini" ? config.geminiModel : config.aiEditorModel)
            : nil
    }
}


enum RuntimeRevalidationReason: Sendable, Equatable {
    case credentials(provider: String)
    case model(id: String)
    case retry
}

private struct RuntimeForceTargets: OptionSet, Sendable {
    let rawValue: UInt8

    static let transcriber = RuntimeForceTargets(rawValue: 1 << 0)
    static let editor = RuntimeForceTargets(rawValue: 1 << 1)
    static let all: RuntimeForceTargets = [.transcriber, .editor]
}

enum RuntimeCoordinatorState: Sendable, Equatable {
    case uninitialized
    case preparing(desired: RuntimeSelection)
    case ready(active: RuntimeDescriptor)
    case reconfiguring(active: RuntimeDescriptor, desired: RuntimeSelection)
    case degraded(
        active: RuntimeDescriptor?,
        desired: RuntimeSelection,
        message: String,
        recovery: [RuntimeRecoveryCommand]
    )
    case stopping
}

enum RuntimeCommitStage: Sendable, Equatable {
    case beforeTranscriberInstall
    case betweenRouterInstalls
}

private enum RuntimeCommitError: LocalizedError {
    case installationRejected(component: String)

    var errorDescription: String? {
        switch self {
        case let .installationRejected(component):
            "The prepared \(component) runtime could not be activated"
        }
    }
}

@MainActor
protocol RuntimeSessionCoordinating: AnyObject {
    var isRuntimeIdle: Bool { get }
    func beginRuntimeMutation() -> Bool
    func endRuntimeMutation()
    func updateConfig(_ config: Config)
    func setRuntimeAvailable(_ available: Bool)
}

extension SessionController: RuntimeSessionCoordinating {}

/// Serializes desired configuration changes and activates prepared candidates
/// only while the session is idle. A failed or superseded candidate never
/// replaces the working services retained by the routers.
@MainActor
final class AppRuntimeCoordinator {
    private let transcriberRouter: TranscriberRouter
    private let editorRouter: AiEditorRouter
    private let factory: any RuntimeServiceBuilding
    private weak var session: (any RuntimeSessionCoordinating)?
    private let configURL: URL
    private let log: @Sendable (String) -> Void
    private let commitBarrier: @Sendable (RuntimeCommitStage) async -> Void

    private var activeConfig: Config?
    private var activeRuntime: RuntimeDescriptor?
    private var dictionarySnapshot: Config
    private var desiredConfig: Config
    private var desiredGeneration = 0
    private var pendingTask: Task<Void, Never>?
    private var committingGeneration: Int?
    private var postCommitApplyPending = false
    private var dictionaryUpdateDuringCommit = false
    private var shutdownRequested = false
    private var commitCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var desiredForceTargets: RuntimeForceTargets = []
    private var credentialRevalidationProviders = Set<String>()
    private var invalidatedCredentialProviders = Set<String>()

    private(set) var state: RuntimeCoordinatorState = .uninitialized {
        didSet { onStateChanged?(state) }
    }

    var onStateChanged: ((RuntimeCoordinatorState) -> Void)?
    /// Acknowledges a successful corresponding config write (including an
    /// externally persisted reload). Runs before router awaits, so a later
    /// dictionary publication can never be acknowledged as already persisted.
    var onConfigActivated: ((Config) -> Void)?

    var desiredConfiguration: Config { desiredConfig }

    /// The dictionary owner publishes data, not a runtime selection or a write
    /// acknowledgement. Preserve both the active and pending runtime choices.
    func updateDictionarySnapshot(_ config: Config) {
        let languageChanged = languageSettingsDiffer(dictionarySnapshot, config)
        dictionarySnapshot = config
        desiredConfig = mergingDictionaryFields(into: desiredConfig, adoptingLanguageSettings: true)
        if committingGeneration != nil {
            dictionaryUpdateDuringCommit = true
            return
        }
        // A preparation task may have captured the previous language/prompt.
        // Supersede it before it can persist stale bytes, then prepare the
        // latest desired snapshot. Ready/degraded runtimes adopt data-only
        // changes without restarting services.
        if languageChanged {
            switch state {
            case .preparing, .reconfiguring:
                requestConfiguration(desiredConfig)
            default:
                break
            }
        }
        if let activeConfig {
            let updated = mergingDictionaryFields(into: activeConfig, adoptingLanguageSettings: true)
            self.activeConfig = updated
            if let activeRuntime {
                publishActiveRuntimeToSession(config: updated, runtime: activeRuntime)
            }
        }
    }

    private func mergingDictionaryFields(
        into config: Config,
        adoptingLanguageSettings: Bool = false
    ) -> Config {
        let languageSettingsChanged = languageSettingsDiffer(config, dictionarySnapshot)
        var merged = config
        for key in Self.dictionaryOwnedKeys {
            merged.raw[key] = dictionarySnapshot.raw[key]
        }
        if adoptingLanguageSettings {
            for key in Self.languageSettingsKeys {
                merged.raw[key] = dictionarySnapshot.raw[key]
            }
        }
        if languageSettingsChanged && !adoptingLanguageSettings {
            merged.raw["initial_prompt"] = .string(
                InitialPromptBuilder().build(config: merged.raw)
            )
        }
        return merged
    }

    private func languageSettingsDiffer(_ lhs: Config, _ rhs: Config) -> Bool {
        let lhsPrimary = lhs.primaryLanguage
        let rhsPrimary = rhs.primaryLanguage
        return lhsPrimary != rhsPrimary
            || LanguageCode.dedupeList(lhs.additionalLanguages, primary: lhsPrimary)
                != LanguageCode.dedupeList(rhs.additionalLanguages, primary: rhsPrimary)
            || (lhs.raw["language_auto_detect"]?.boolValue ?? false)
                != (rhs.raw["language_auto_detect"]?.boolValue ?? false)
    }

    // Extend this ownership contract when adding mutable dictionary settings.
    private static let dictionaryOwnedKeys = [
        "user_terms", "initial_prompt", "prompt_snapshots", "pending_suggestions",
        "skipped_terms", "prompt_update_mode", "last_analysis_phrase_count",
        "last_decay_run_ts", "last_metrics_snapshot_ts", "last_metrics_notification_ts",
        "manual_replacements", "approved_auto_replacements", "rejected_replacements",
        "replacement_policy_initialized", "auto_prompt_check_interval",
        "auto_prompt_check_min_count_primary", "auto_prompt_check_min_count_additional",
        "auto_prompt_lookback", "max_dictionary_age_days", "notify_on_metrics"
    ]
    private static let languageSettingsKeys = [
        "primary_language", "additional_languages", "language_auto_detect", "language_picker_done"
    ]

    init(
        initialConfig: Config,
        transcriberRouter: TranscriberRouter,
        editorRouter: AiEditorRouter,
        factory: any RuntimeServiceBuilding,
        session: any RuntimeSessionCoordinating,
        configURL: URL,
        commitBarrier: @escaping @Sendable (RuntimeCommitStage) async -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dictionarySnapshot = initialConfig
        self.desiredConfig = initialConfig
        self.transcriberRouter = transcriberRouter
        self.editorRouter = editorRouter
        self.factory = factory
        self.session = session
        self.configURL = configURL
        self.commitBarrier = commitBarrier
        self.log = log
        session.setRuntimeAvailable(false)
    }

    var canRecord: Bool { activeRuntime?.transcriber.readiness == .ready }

    func activateInitial(_ config: Config) async {
        guard !shutdownRequested else { return }
        pendingTask?.cancel()
        desiredForceTargets = []
        credentialRevalidationProviders.removeAll()
        invalidatedCredentialProviders.removeAll()
        desiredGeneration += 1
        desiredConfig = mergingDictionaryFields(into: config)
        await apply(
            config: desiredConfig,
            generation: desiredGeneration,
            forceTargets: [],
            credentialProviders: []
        )
    }

    func requestConfiguration(_ config: Config) {
        guard !shutdownRequested else { return }
        let config = mergingDictionaryFields(into: config)
        desiredConfig = config
        desiredGeneration += 1
        let generation = desiredGeneration

        if committingGeneration != nil {
            postCommitApplyPending = true
            state = activeRuntime.map {
                .reconfiguring(active: $0, desired: RuntimeSelection(config: config))
            } ?? .preparing(desired: RuntimeSelection(config: config))
            return
        }
        pendingTask?.cancel()

        if desiredForceTargets.isEmpty,
           let activeConfig, RuntimeSelection(config: activeConfig) == RuntimeSelection(config: config),
           let activeRuntime {
            activateDataOnlyConfig(config, runtime: activeRuntime)
            return
        }

        state = activeRuntime.map {
            .reconfiguring(active: $0, desired: RuntimeSelection(config: config))
        } ?? .preparing(desired: RuntimeSelection(config: config))
        let forceTargets = desiredForceTargets
        let credentialProviders = credentialRevalidationProviders
        pendingTask = Task { [weak self] in
            await self?.apply(
                config: config,
                generation: generation,
                forceTargets: forceTargets,
                credentialProviders: credentialProviders
            )
        }
    }

    func revalidateDesiredConfiguration(reason: RuntimeRevalidationReason) {
        guard !shutdownRequested else { return }
        let targets = forceTargets(for: reason, config: desiredConfig)
        guard !targets.isEmpty else { return }
        desiredForceTargets.formUnion(targets)
        if case let .credentials(provider) = reason {
            let provider = provider.lowercased()
            credentialRevalidationProviders.insert(provider)
            quarantineActiveCredentialRuntime()
        }
        requestConfiguration(desiredConfig)
    }

    func keepPreviousRuntime(generation: Int) {
        guard !shutdownRequested else { return }
        guard generation == desiredGeneration else { return }
        guard let activeConfig, let activeRuntime else { return }
        guard activeRuntime.transcriber.readiness == .ready else { return }
        guard !runtimeUsesPendingCredential(activeRuntime) else { return }
        desiredForceTargets = []
        credentialRevalidationProviders.removeAll()
        invalidatedCredentialProviders.removeAll()
        if committingGeneration != nil {
            let previous = mergingDictionaryFields(into: activeConfig)
            desiredConfig = previous
            desiredGeneration += 1
            postCommitApplyPending = true
            state = .reconfiguring(
                active: activeRuntime,
                desired: RuntimeSelection(config: previous)
            )
            return
        }
        desiredGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        do {
            try activeConfig.saveAtomically(to: configURL)
            desiredConfig = activeConfig
            session?.updateConfig(activeConfig)
            session?.setRuntimeAvailable(activeRuntime.transcriber.readiness == .ready)
            state = .ready(active: activeRuntime)
            onConfigActivated?(activeConfig)
        } catch {
            state = .degraded(
                active: activeRuntime,
                desired: RuntimeSelection(config: activeConfig),
                message: error.localizedDescription,
                recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: desiredGeneration)]
            )
        }
    }

    /// Full external adoption is reserved for a configuration already written
    /// to disk, such as explicit Reload Config. This may replace dictionary
    /// ownership and intentionally supersede a pending runtime selection.
    func adoptPersistedConfiguration(_ config: Config) {
        guard !shutdownRequested else { return }
        desiredForceTargets = []
        credentialRevalidationProviders.removeAll()
        invalidatedCredentialProviders.removeAll()
        dictionarySnapshot = config
        onConfigActivated?(config)
        if committingGeneration != nil {
            desiredConfig = config
            desiredGeneration += 1
            postCommitApplyPending = true
            state = activeRuntime.map {
                .reconfiguring(active: $0, desired: RuntimeSelection(config: config))
            } ?? .preparing(desired: RuntimeSelection(config: config))
            return
        }
        guard let activeRuntime, let activeConfig else {
            requestConfiguration(config)
            return
        }
        guard RuntimeSelection(config: activeConfig) == RuntimeSelection(config: config) else {
            requestConfiguration(config)
            return
        }
        desiredGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        self.activeConfig = config
        desiredConfig = config
        session?.updateConfig(config)
        state = .ready(active: activeRuntime)
    }

    func shutdown() async {
        shutdownRequested = true
        state = .stopping
        desiredGeneration += 1
        if committingGeneration == nil {
            pendingTask?.cancel()
        }
        if committingGeneration != nil {
            await withCheckedContinuation { continuation in
                if committingGeneration == nil {
                    continuation.resume()
                } else {
                    commitCompletionWaiters.append(continuation)
                }
            }
        }
        pendingTask?.cancel()
        pendingTask = nil
        session?.setRuntimeAvailable(false)
        transcriberRouter.abortInFlight()
        await editorRouter.stop()
        await transcriberRouter.stop()
        activeRuntime = nil
        session?.setRuntimeAvailable(false)
        state = .stopping
    }

    private func apply(
        config: Config,
        generation: Int,
        forceTargets: RuntimeForceTargets,
        credentialProviders: Set<String>
    ) async {
        let desired = RuntimeSelection(config: config)
        if state == .uninitialized {
            state = .preparing(desired: desired)
        }

        do {
            try await waitUntilSessionIsIdle(generation: generation)
            try ensureCurrent(generation)

            let previousSelection = activeConfig.map(RuntimeSelection.init(config:))
            let needsTranscriber = forceTargets.contains(.transcriber)
                || previousSelection == nil
                || previousSelection?.sttBackend != desired.sttBackend
                || previousSelection?.sttModelID != desired.sttModelID
            let needsEditor = forceTargets.contains(.editor)
                || previousSelection == nil
                || previousSelection?.editorEnabled != desired.editorEnabled
                || previousSelection?.editorBackend != desired.editorBackend
                || previousSelection?.editorModelID != desired.editorModelID

            var preparedTranscriber: PreparedTranscriber?
            var preparedEditor: PreparedEditor?
            var initialEditorError: Error?
            do {
                if needsTranscriber {
                    preparedTranscriber = try await factory.prepareTranscriber(config: config, generation: generation)
                    try ensureCurrent(generation)
                }
                if needsEditor {
                    do {
                        preparedEditor = try await factory.prepareEditor(config: config, generation: generation)
                        try ensureCurrent(generation)
                    } catch {
                        if activeRuntime == nil, preparedTranscriber != nil {
                            initialEditorError = error
                        }
                        if initialEditorError == nil { throw error }
                    }
                }
            } catch {
                if let preparedTranscriber { await preparedTranscriber.service.stop() }
                if let editor = preparedEditor?.service { await editor.stop() }
                throw error
            }

            do {
                try await beginRuntimeCommit(generation: generation)
            } catch {
                if let preparedTranscriber { await preparedTranscriber.service.stop() }
                if let editor = preparedEditor?.service { await editor.stop() }
                throw error
            }
            defer { finishRuntimeCommit(generation: generation) }

            if let initialEditorError, let preparedTranscriber {
                try await activateInitialTranscriberOnly(
                    preparedTranscriber,
                    desiredConfig: config,
                    generation: generation,
                    editorError: initialEditorError
                )
                return
            }

            let runtime = try await commitPreparedRuntime(
                config: config,
                generation: generation,
                preparedTranscriber: preparedTranscriber,
                preparedEditor: preparedEditor
            )
            // Dictionary state may have changed during router installation.
            let activatedConfig = mergingDictionaryFields(into: config)
            activeConfig = activatedConfig
            activeRuntime = runtime
            consumeRevalidationIfCurrent(
                generation: generation,
                targets: forceTargets,
                credentialProviders: credentialProviders
            )
            publishActiveRuntimeToSession(config: activatedConfig, runtime: runtime)
            if shutdownRequested {
                state = .stopping
            } else if desiredGeneration == generation, !postCommitApplyPending {
                state = .ready(active: runtime)
            } else {
                state = .reconfiguring(
                    active: runtime,
                    desired: RuntimeSelection(config: desiredConfig)
                )
            }
            RuntimeTelemetry.emitRuntimeEvent("runtime_activated", fields: [
                "generation": generation,
                "stt_backend": runtime.transcriber.backend,
                "stt_model": runtime.transcriber.modelID,
                "ai_backend": runtime.aiEditor.backend,
                "ai_model": runtime.aiEditor.modelID ?? "none"
            ])
        } catch is CancellationError {
            log("Runtime preparation generation \(generation) was superseded.")
        } catch {
            guard generation == desiredGeneration else { return }
            let deactivatedCredential = await deactivateUnavailableCredentialIfNeeded(
                error: error,
                config: config,
                generation: generation,
                forceTargets: forceTargets,
                credentialProviders: credentialProviders
            )
            guard generation == desiredGeneration else { return }
            let message = error.localizedDescription
            if let activeConfig, let activeRuntime {
                publishActiveRuntimeToSession(config: activeConfig, runtime: activeRuntime)
            } else {
                session?.setRuntimeAvailable(false)
            }
            state = .degraded(
                active: activeRuntime,
                desired: desired,
                message: message,
                recovery: recoveryActions(generation: generation, 
                    for: error,
                    deactivatedCredential: deactivatedCredential
                )
            )
            log("Runtime activation failed: \(message)")
            RuntimeTelemetry.emitRuntimeEvent("runtime_activation_failed", fields: [
                "generation": generation,
                "error_kind": telemetryErrorKind(for: error)
            ])
        }
    }

    /// Persist first, then publish both candidates while the session owns an
    /// exclusive runtime mutation reservation. Once the first router install
    /// starts, a newer intent is queued for the next commit instead of
    /// cancelling this one between the two publications.
    private func commitPreparedRuntime(
        config: Config,
        generation: Int,
        preparedTranscriber: PreparedTranscriber?,
        preparedEditor: PreparedEditor?
    ) async throws -> RuntimeDescriptor {
        var transcriberInstallation: TranscriberRouterInstallation?
        var editorInstallation: AiEditorRouterInstallation?
        do {
            let persistedConfig = mergingDictionaryFields(into: config)
            try persistedConfig.saveAtomically(to: configURL)
            onConfigActivated?(persistedConfig)

            if let preparedTranscriber {
                await commitBarrier(.beforeTranscriberInstall)
                transcriberInstallation = await transcriberRouter.stageInstall(
                    preparedTranscriber.service,
                    descriptor: preparedTranscriber.descriptor,
                    activationGeneration: generation
                )
                guard transcriberInstallation != nil else {
                    throw RuntimeCommitError.installationRejected(component: "transcription")
                }
            }
            if let preparedEditor {
                if transcriberInstallation != nil {
                    await commitBarrier(.betweenRouterInstalls)
                }
                editorInstallation = await editorRouter.stageInstall(
                    preparedEditor.service,
                    descriptor: preparedEditor.descriptor,
                    activationGeneration: generation
                )
                guard editorInstallation != nil else {
                    throw RuntimeCommitError.installationRejected(component: "editor")
                }
            }
            if let transcriberInstallation {
                await transcriberRouter.commit(transcriberInstallation)
            }
            if let editorInstallation {
                await editorRouter.commit(editorInstallation)
            }
        } catch {
            if let editorInstallation {
                await editorRouter.rollback(editorInstallation)
            } else if let editor = preparedEditor?.service {
                await editor.stop()
            }
            if let transcriberInstallation {
                await transcriberRouter.rollback(transcriberInstallation)
            } else if let preparedTranscriber {
                await preparedTranscriber.service.stop()
            }
            throw error
        }

        return RuntimeDescriptor(
            transcriber: transcriberRouter.currentDescriptorSnapshot,
            aiEditor: editorRouter.currentDescriptorSnapshot
        )
    }

    private func activateDataOnlyConfig(_ config: Config, runtime: RuntimeDescriptor) {
        do {
            try config.saveAtomically(to: configURL)
            activeConfig = config
            desiredConfig = config
            session?.updateConfig(config)
            state = .ready(active: runtime)
            onConfigActivated?(config)
        } catch {
            state = .degraded(
                active: runtime,
                desired: RuntimeSelection(config: config),
                message: error.localizedDescription,
                recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: desiredGeneration), RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: desiredGeneration)]
            )
        }
    }

    private func activateInitialTranscriberOnly(
        _ prepared: PreparedTranscriber,
        desiredConfig: Config,
        generation: Int,
        editorError: Error
    ) async throws {
        await commitBarrier(.beforeTranscriberInstall)
        guard let transcriberInstallation = await transcriberRouter.stageInstall(
            prepared.service,
            descriptor: prepared.descriptor,
            activationGeneration: generation
        ) else {
            await prepared.service.stop()
            throw RuntimeCommitError.installationRejected(component: "transcription")
        }
        await commitBarrier(.betweenRouterInstalls)
        guard let editorInstallation = await editorRouter.stageInstall(
            nil,
            descriptor: .disabled,
            activationGeneration: generation
        ) else {
            await transcriberRouter.rollback(transcriberInstallation)
            throw RuntimeCommitError.installationRejected(component: "editor")
        }
        await transcriberRouter.commit(transcriberInstallation)
        await editorRouter.commit(editorInstallation)
        let runtime = RuntimeDescriptor(
            transcriber: prepared.descriptor,
            aiEditor: .disabled
        )
        var effectiveConfig = mergingDictionaryFields(into: desiredConfig)
        effectiveConfig.raw["ai_editor_enabled"] = .bool(false)
        activeConfig = effectiveConfig
        activeRuntime = runtime
        // Recording remains available with the successfully prepared STT, but
        // the session must not attempt to invoke the unavailable editor.
        publishActiveRuntimeToSession(config: effectiveConfig, runtime: runtime)
        state = shutdownRequested
            ? .stopping
            : .degraded(
                active: runtime,
                desired: RuntimeSelection(config: desiredConfig),
                message: editorError.localizedDescription,
                recovery: recoveryActions(generation: generation, for: editorError)
            )
        RuntimeTelemetry.emitRuntimeEvent("runtime_partially_activated", fields: [
            "generation": generation,
            "stt_backend": runtime.transcriber.backend,
            "stt_model": runtime.transcriber.modelID,
            "disabled_component": "ai_editor"
        ])
    }

    private func waitUntilSessionIsIdle(generation: Int) async throws {
        while session?.isRuntimeIdle == false {
            try ensureCurrent(generation)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func beginRuntimeCommit(generation: Int) async throws {
        while true {
            try ensureCurrent(generation)
            guard let session else {
                committingGeneration = generation
                return
            }
            if session.beginRuntimeMutation() {
                do {
                    try ensureCurrent(generation)
                    committingGeneration = generation
                    return
                } catch {
                    session.endRuntimeMutation()
                    throw error
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func finishRuntimeCommit(generation: Int) {
        session?.endRuntimeMutation()
        committingGeneration = nil
        if dictionaryUpdateDuringCommit, let activeConfig {
            let updated = mergingDictionaryFields(into: activeConfig, adoptingLanguageSettings: true)
            self.activeConfig = updated
            if let activeRuntime {
                publishActiveRuntimeToSession(config: updated, runtime: activeRuntime)
            }
        }
        dictionaryUpdateDuringCommit = false
        let waiters = commitCompletionWaiters
        commitCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        let shouldApplyPending = !shutdownRequested
            && (postCommitApplyPending || desiredGeneration != generation)
        postCommitApplyPending = false
        guard shouldApplyPending else { return }
        requestConfiguration(desiredConfig)
    }

    private func consumeRevalidationIfCurrent(
        generation: Int,
        targets: RuntimeForceTargets,
        credentialProviders: Set<String>
    ) {
        guard generation == desiredGeneration else { return }
        desiredForceTargets.subtract(targets)
        invalidatedCredentialProviders.subtract(credentialProviders)
        if desiredForceTargets.isEmpty {
            credentialRevalidationProviders.removeAll()
        }
    }

    private func forceTargets(
        for reason: RuntimeRevalidationReason,
        config: Config
    ) -> RuntimeForceTargets {
        switch reason {
        case let .credentials(provider):
            let provider = provider.lowercased()
            var targets: RuntimeForceTargets = []
            if config.sttBackend.lowercased() == provider {
                targets.insert(.transcriber)
            }
            if config.aiEditorEnabled, config.aiEditorBackend.lowercased() == provider {
                targets.insert(.editor)
            }
            return targets
        case let .model(id):
            var targets: RuntimeForceTargets = []
            if config.sttBackend == "local", localSTTModel(config: config, matches: id) {
                targets.insert(.transcriber)
            }
            if config.aiEditorEnabled,
               config.aiEditorBackend == "local",
               localEditorModel(config: config, matches: id) {
                targets.insert(.editor)
            }
            return targets
        case .retry:
            return .all
        }
    }

    private func localSTTModel(config: Config, matches id: String) -> Bool {
        if config.sttModelName == id { return true }
        return ModelRegistry.whisperModelByLegacyID(config.sttModelName)?.id == id
    }

    private func localEditorModel(config: Config, matches id: String) -> Bool {
        if config.aiEditorModel == id { return true }
        if ModelRegistry.aiEditorModel(id: config.aiEditorModel)?.id == id { return true }
        if config.aiEditorModel == "mlx-community/Qwen2.5-1.5B-Instruct-4bit" {
            return ModelRegistry.defaultAiEditorModelID == id
        }
        return false
    }

    /// Existing activities retain their captured runtime snapshot, while new
    /// activities cannot start with a client whose credential just changed.
    private func quarantineActiveCredentialRuntime() {
        guard let activeConfig, let activeRuntime else { return }
        publishActiveRuntimeToSession(config: activeConfig, runtime: activeRuntime)
    }

    private func publishActiveRuntimeToSession(
        config: Config,
        runtime: RuntimeDescriptor
    ) {
        var effectiveConfig = config
        var runtimeAvailable = !shutdownRequested
            && runtime.transcriber.readiness == .ready
        for provider in credentialRevalidationProviders {
            if desiredForceTargets.contains(.transcriber),
               runtime.transcriber.backend.lowercased() == provider {
                runtimeAvailable = false
            }
            if desiredForceTargets.contains(.editor),
               runtime.aiEditor.backend.lowercased() == provider {
                effectiveConfig.raw["ai_editor_enabled"] = .bool(false)
            }
        }
        session?.updateConfig(effectiveConfig)
        session?.setRuntimeAvailable(runtimeAvailable)
    }

    private func runtimeUsesPendingCredential(_ runtime: RuntimeDescriptor) -> Bool {
        credentialRevalidationProviders.contains { provider in
            (desiredForceTargets.contains(.transcriber)
                && runtime.transcriber.backend.lowercased() == provider)
                || (desiredForceTargets.contains(.editor)
                    && runtime.aiEditor.backend.lowercased() == provider)
        }
    }

    /// Credential deletion invalidates the already constructed client. Once
    /// the session becomes idle, remove only the affected cloud components so
    /// no later request can silently keep using the previous secret.
    private func deactivateUnavailableCredentialIfNeeded(
        error: Error,
        config: Config,
        generation: Int,
        forceTargets: RuntimeForceTargets,
        credentialProviders: Set<String>
    ) async -> Bool {
        guard case let RuntimePreparationError.credentialMissing(backend) = error else {
            return false
        }
        let provider = backend.lowercased()
        guard credentialProviders.contains(provider), let activeRuntime else { return false }
        let disableTranscriber = forceTargets.contains(.transcriber)
            && activeRuntime.transcriber.backend.lowercased() == provider
        let disableEditor = forceTargets.contains(.editor)
            && activeRuntime.aiEditor.backend.lowercased() == provider
        guard disableTranscriber || disableEditor else { return false }

        do {
            try await beginRuntimeCommit(generation: generation)
        } catch {
            return false
        }
        defer { finishRuntimeCommit(generation: generation) }

        var transcriberInstallation: TranscriberRouterInstallation?
        var editorInstallation: AiEditorRouterInstallation?
        do {
            if disableTranscriber {
                await commitBarrier(.beforeTranscriberInstall)
                transcriberInstallation = await transcriberRouter.stageDisable(
                    activationGeneration: generation
                )
                guard transcriberInstallation != nil else {
                    throw RuntimeCommitError.installationRejected(component: "transcription")
                }
            }
            if disableEditor {
                if transcriberInstallation != nil {
                    await commitBarrier(.betweenRouterInstalls)
                }
                editorInstallation = await editorRouter.stageInstall(
                    nil,
                    descriptor: .disabled,
                    activationGeneration: generation
                )
                guard editorInstallation != nil else {
                    throw RuntimeCommitError.installationRejected(component: "editor")
                }
            }
            if let transcriberInstallation {
                await transcriberRouter.commit(transcriberInstallation)
            }
            if let editorInstallation {
                await editorRouter.commit(editorInstallation)
            }
        } catch {
            if let editorInstallation {
                await editorRouter.rollback(editorInstallation)
            }
            if let transcriberInstallation {
                await transcriberRouter.rollback(transcriberInstallation)
            }
            return false
        }

        let runtime = RuntimeDescriptor(
            transcriber: transcriberRouter.currentDescriptorSnapshot,
            aiEditor: editorRouter.currentDescriptorSnapshot
        )
        var effectiveConfig = mergingDictionaryFields(into: self.activeConfig ?? config)
        if disableEditor {
            effectiveConfig.raw["ai_editor_enabled"] = .bool(false)
        }
        self.activeConfig = effectiveConfig
        self.activeRuntime = runtime
        invalidatedCredentialProviders.insert(provider)
        session?.updateConfig(effectiveConfig)
        session?.setRuntimeAvailable(runtime.transcriber.readiness == .ready)
        RuntimeTelemetry.emitRuntimeEvent("runtime_credential_invalidated", fields: [
            "generation": generation,
            "provider": provider,
            "stt_disabled": disableTranscriber,
            "editor_disabled": disableEditor
        ])
        return true
    }

    private func recoveryActions(generation: Int, 
        for error: Error,
        deactivatedCredential: Bool
    ) -> [RuntimeRecoveryCommand] {
        if deactivatedCredential {
            let provider = (error as? RuntimePreparationError).flatMap { e -> String? in
                if case .credentialMissing(let b) = e { return b.lowercased() }
                return nil
            } ?? "gemini"
            return [RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: provider), generation: generation)]
        }
        if case let RuntimePreparationError.credentialMissing(backend) = error,
           invalidatedCredentialProviders.contains(backend.lowercased()) {
            return [RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: backend.lowercased()), generation: generation)]
        }
        if let activeRuntime, runtimeUsesPendingCredential(activeRuntime) {
            if let prepError = error as? RuntimePreparationError {
                var cmds = [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation)]
                if case .credentialMissing(let b) = prepError {
                    cmds.append(RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: b.lowercased()), generation: generation))
                }
                return cmds
            }
            return [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation)]
        }
        return recoveryActions(generation: generation, for: error)
    }

    private func ensureCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == desiredGeneration else { throw CancellationError() }
    }

    private func recoveryActions(generation: Int, for error: Error) -> [RuntimeRecoveryCommand] {
        guard let error = error as? RuntimePreparationError else {
            return [
                RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: generation)
            ]
        }
        switch error {
        case .modelMissing(let id):
            return [
                RuntimeRecoveryCommand(kind: .download, target: .localModel(id: id), generation: generation),
                RuntimeRecoveryCommand(kind: .selectCloudBackend, target: .general, generation: generation),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: generation)
            ]
        case .modelCorrupted(let id):
            return [
                RuntimeRecoveryCommand(kind: .redownload, target: .localModel(id: id), generation: generation),
                RuntimeRecoveryCommand(kind: .selectCloudBackend, target: .general, generation: generation),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: generation)
            ]
        case .credentialMissing(let backend):
            return [
                RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: backend), generation: generation),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: generation)
            ]
        case .unsupportedBackend, .unsupportedModel, .initializationFailed:
            return [
                RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: generation)
            ]
        }
    }

    private func telemetryErrorKind(for error: Error) -> String {
        if error is RuntimeCommitError { return "router_installation_rejected" }
        guard let error = error as? RuntimePreparationError else {
            return error is CancellationError ? "cancelled" : "unexpected"
        }
        switch error {
        case .modelMissing:
            return "model_missing"
        case .modelCorrupted:
            return "model_corrupted"
        case .credentialMissing:
            return "credential_missing"
        case .unsupportedBackend:
            return "unsupported_backend"
        case .unsupportedModel:
            return "unsupported_model"
        case .initializationFailed:
            return "initialization_failed"
        }
    }
}
