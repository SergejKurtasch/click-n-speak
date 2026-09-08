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

enum RuntimeRecoveryAction: String, Sendable, Equatable {
    case downloadModel
    case openAPIKeys
    case selectCloudBackend
    case keepPreviousRuntime
    case retry
    case redownloadModel
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
        recovery: [RuntimeRecoveryAction]
    )
    case stopping
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

    private var activeConfig: Config?
    private var activeRuntime: RuntimeDescriptor?
    private var dictionarySnapshot: Config
    private var desiredConfig: Config
    private var desiredGeneration = 0
    private var pendingTask: Task<Void, Never>?

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
        dictionarySnapshot = config
        desiredConfig = mergingDictionaryFields(into: desiredConfig)
        if let activeConfig {
            let updated = mergingDictionaryFields(into: activeConfig)
            self.activeConfig = updated
            session?.updateConfig(updated)
        }
    }

    private func mergingDictionaryFields(into config: Config) -> Config {
        var merged = config
        for key in Self.dictionaryOwnedKeys {
            merged.raw[key] = dictionarySnapshot.raw[key]
        }
        return merged
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

    init(
        initialConfig: Config,
        transcriberRouter: TranscriberRouter,
        editorRouter: AiEditorRouter,
        factory: any RuntimeServiceBuilding,
        session: any RuntimeSessionCoordinating,
        configURL: URL,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dictionarySnapshot = initialConfig
        self.desiredConfig = initialConfig
        self.transcriberRouter = transcriberRouter
        self.editorRouter = editorRouter
        self.factory = factory
        self.session = session
        self.configURL = configURL
        self.log = log
        session.setRuntimeAvailable(false)
    }

    var canRecord: Bool { activeRuntime?.transcriber.readiness == .ready }

    func activateInitial(_ config: Config) async {
        pendingTask?.cancel()
        desiredGeneration += 1
        desiredConfig = mergingDictionaryFields(into: config)
        await apply(config: desiredConfig, generation: desiredGeneration)
    }

    func requestConfiguration(_ config: Config) {
        let config = mergingDictionaryFields(into: config)
        desiredConfig = config
        desiredGeneration += 1
        let generation = desiredGeneration
        pendingTask?.cancel()

        if let activeConfig, RuntimeSelection(config: activeConfig) == RuntimeSelection(config: config),
           let activeRuntime {
            activateDataOnlyConfig(config, runtime: activeRuntime)
            return
        }

        state = activeRuntime.map {
            .reconfiguring(active: $0, desired: RuntimeSelection(config: config))
        } ?? .preparing(desired: RuntimeSelection(config: config))
        pendingTask = Task { [weak self] in
            await self?.apply(config: config, generation: generation)
        }
    }

    func revalidateDesiredConfiguration() {
        requestConfiguration(desiredConfig)
    }

    func keepPreviousRuntime() {
        guard let activeConfig, let activeRuntime else { return }
        desiredGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        do {
            try activeConfig.saveAtomically(to: configURL)
            desiredConfig = activeConfig
            session?.updateConfig(activeConfig)
            session?.setRuntimeAvailable(true)
            state = .ready(active: activeRuntime)
            onConfigActivated?(activeConfig)
        } catch {
            state = .degraded(
                active: activeRuntime,
                desired: RuntimeSelection(config: activeConfig),
                message: error.localizedDescription,
                recovery: [.retry]
            )
        }
    }

    /// Full external adoption is reserved for a configuration already written
    /// to disk, such as explicit Reload Config. This may replace dictionary
    /// ownership and intentionally supersede a pending runtime selection.
    func adoptPersistedConfiguration(_ config: Config) {
        dictionarySnapshot = config
        onConfigActivated?(config)
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
        state = .stopping
        desiredGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        session?.setRuntimeAvailable(false)
        transcriberRouter.abortInFlight()
        await editorRouter.stop()
        await transcriberRouter.stop()
        activeRuntime = nil
    }

    private func apply(config: Config, generation: Int) async {
        let desired = RuntimeSelection(config: config)
        if state == .uninitialized {
            state = .preparing(desired: desired)
        }

        do {
            try await waitUntilSessionIsIdle(generation: generation)
            try ensureCurrent(generation)

            let previousSelection = activeConfig.map(RuntimeSelection.init(config:))
            let needsTranscriber = previousSelection == nil
                || previousSelection?.sttBackend != desired.sttBackend
                || previousSelection?.sttModelID != desired.sttModelID
            let needsEditor = previousSelection == nil
                || previousSelection?.editorEnabled != desired.editorEnabled
                || previousSelection?.editorBackend != desired.editorBackend
                || previousSelection?.editorModelID != desired.editorModelID

            var preparedTranscriber: PreparedTranscriber?
            var preparedEditor: PreparedEditor?
            do {
                if needsTranscriber {
                    preparedTranscriber = try await factory.prepareTranscriber(config: config)
                    try ensureCurrent(generation)
                }
                if needsEditor {
                    do {
                        preparedEditor = try await factory.prepareEditor(config: config)
                        try ensureCurrent(generation)
                    } catch {
                        if activeRuntime == nil, let preparedTranscriber {
                            try ensureCurrent(generation)
                            try await activateInitialTranscriberOnly(
                                preparedTranscriber,
                                desiredConfig: config,
                                generation: generation,
                                editorError: error
                            )
                            return
                        }
                        throw error
                    }
                }
            } catch {
                if let preparedTranscriber { await preparedTranscriber.service.stop() }
                if let editor = preparedEditor?.service { await editor.stop() }
                throw error
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
            session?.updateConfig(activatedConfig)
            session?.setRuntimeAvailable(true)
            state = .ready(active: runtime)
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
            let message = error.localizedDescription
            session?.setRuntimeAvailable(activeRuntime != nil)
            state = .degraded(
                active: activeRuntime,
                desired: desired,
                message: message,
                recovery: recoveryActions(for: error)
            )
            log("Runtime activation failed: \(message)")
            RuntimeTelemetry.emitRuntimeEvent("runtime_activation_failed", fields: [
                "generation": generation,
                "error_kind": telemetryErrorKind(for: error)
            ])
        }
    }

    /// Persist first, then publish candidates through generation-aware routers.
    /// A failed write leaves the active services untouched, while a superseded
    /// task can no longer overwrite a newer router generation after an `await`.
    private func commitPreparedRuntime(
        config: Config,
        generation: Int,
        preparedTranscriber: PreparedTranscriber?,
        preparedEditor: PreparedEditor?
    ) async throws -> RuntimeDescriptor {
        var transcriberInstalled = false
        var editorInstalled = false
        do {
            try ensureCurrent(generation)
            let persistedConfig = mergingDictionaryFields(into: config)
            try persistedConfig.saveAtomically(to: configURL)
            onConfigActivated?(persistedConfig)
            try ensureCurrent(generation)

            if let preparedTranscriber {
                transcriberInstalled = await transcriberRouter.install(
                    preparedTranscriber.service,
                    descriptor: preparedTranscriber.descriptor,
                    activationGeneration: generation
                )
                guard transcriberInstalled else { throw CancellationError() }
                try ensureCurrent(generation)
            }
            if let preparedEditor {
                editorInstalled = await editorRouter.install(
                    preparedEditor.service,
                    descriptor: preparedEditor.descriptor,
                    activationGeneration: generation
                )
                guard editorInstalled else { throw CancellationError() }
                try ensureCurrent(generation)
            }
        } catch {
            if let preparedTranscriber, !transcriberInstalled {
                await preparedTranscriber.service.stop()
            }
            if let editor = preparedEditor?.service, !editorInstalled {
                await editor.stop()
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
                recovery: [.retry, .keepPreviousRuntime]
            )
        }
    }

    private func activateInitialTranscriberOnly(
        _ prepared: PreparedTranscriber,
        desiredConfig: Config,
        generation: Int,
        editorError: Error
    ) async throws {
        try ensureCurrent(generation)
        guard await transcriberRouter.install(
            prepared.service,
            descriptor: prepared.descriptor,
            activationGeneration: generation
        ) else {
            await prepared.service.stop()
            throw CancellationError()
        }
        try ensureCurrent(generation)
        guard await editorRouter.install(
            nil,
            descriptor: .disabled,
            activationGeneration: generation
        ) else {
            throw CancellationError()
        }
        try ensureCurrent(generation)
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
        session?.updateConfig(effectiveConfig)
        session?.setRuntimeAvailable(true)
        state = .degraded(
            active: runtime,
            desired: RuntimeSelection(config: desiredConfig),
            message: editorError.localizedDescription,
            recovery: recoveryActions(for: editorError)
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

    private func ensureCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == desiredGeneration else { throw CancellationError() }
    }

    private func recoveryActions(for error: Error) -> [RuntimeRecoveryAction] {
        guard let error = error as? RuntimePreparationError else {
            return [.retry, .keepPreviousRuntime]
        }
        switch error {
        case .modelMissing:
            return [.downloadModel, .selectCloudBackend, .keepPreviousRuntime]
        case .modelCorrupted:
            return [.redownloadModel, .selectCloudBackend, .keepPreviousRuntime]
        case .credentialMissing:
            return [.openAPIKeys, .keepPreviousRuntime]
        case .unsupportedBackend, .unsupportedModel, .initializationFailed:
            return [.retry, .keepPreviousRuntime]
        }
    }

    private func telemetryErrorKind(for error: Error) -> String {
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
