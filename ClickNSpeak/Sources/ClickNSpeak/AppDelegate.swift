import AppKit
import CNSAudio
import CNSCore
import CNSDictionary
import CNSEditors
import CNSInput
import CNSSession
import CNSTranscription
import CNSUI

/// Composition root: wires paths, config, i18n, logging and the menu bar
/// together. Mirrors the startup sequence in `main.py` (instance lock →
/// config load → i18n → coordinators → menu/runtime/session activation).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths: Paths
    private let recoveryPresenter: (ConfigRecoveryCoordinator) -> Config?
    private var instanceGuard: SingleInstanceGuard?
    private var menuController: MenuBarController?
    private var modelDownloader: ModelDownloader?
    private var scheduler: MaintenanceScheduler?
    private var logger: FileLogger?
    private var session: SessionController?
    private var hotkey: HotkeyManager?
    private var permissionService: SystemPermissionService?
    private var launchCoordinator: AppLaunchCoordinator?
    private var runtimeCoordinator: AppRuntimeCoordinator?
    private var dictionaryCoordinator: DictionaryCoordinator?
    private var notificationService: UserNotificationService?
    private var launchTask: Task<Void, Never>?
    private var hotkeyStarted = false
    private var keepAliveTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var updateTimer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var terminationStarted = false
    private var menuState: MenuState?

    init(
        paths: Paths = .resolveDefault(),
        recoveryPresenter: @escaping (ConfigRecoveryCoordinator) -> Config? = { $0.present() }
    ) {
        self.paths = paths
        self.recoveryPresenter = recoveryPresenter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? paths.ensureDataDirectory()
        let permissionService = SystemPermissionService(paths: paths)
        self.permissionService = permissionService

        // Single-instance guard: activate the running copy and exit if held.
        let guardInstance = SingleInstanceGuard(lockURL: paths.instanceLockFile)
        guard guardInstance.acquire() else {
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        instanceGuard = guardInstance

        let logger = FileLogger(fileURL: paths.logFile)
        self.logger = logger
        let log: @Sendable (String) -> Void = { message in
            Task { await logger.info(message) }
        }
        let configExisted = FileManager.default.fileExists(atPath: paths.configFile.path)
        let loadedConfig: Config
        do {
            loadedConfig = try Config.loadValidated(from: paths.configFile)
        } catch {
            log("Configuration could not be loaded; startup is awaiting explicit recovery.")
            // Recovery retries only configuration reading, retaining the instance
            // lock. No dictionary/history, watchers, timers or runtime exist yet.
            let recovery = ConfigRecoveryCoordinator(configURL: paths.configFile)
            guard let recovered = recoveryPresenter(recovery) else { return }
            loadedConfig = recovered
        }
        // Persist a migrated default on first run (Python copies config.example.json).
        if !configExisted {
            try? loadedConfig.saveAtomically(to: paths.configFile)
        }

        let notificationService = UserNotificationService(log: log)
        self.notificationService = notificationService
        let resources = AppResources.resolve()
        let phraseHistory = PhraseHistory(fileURL: paths.phraseHistoryFile, log: log)
        let preparedDictionary = Self.prepareDictionaryConfiguration(
            config: loadedConfig,
            paths: paths,
            phraseHistory: phraseHistory,
            log: log
        )
        let dictionaryCoordinator = preparedDictionary.coordinator
        let config = preparedDictionary.config
        let i18n = I18n.load(config.primaryLanguage, localesDirectory: resources.localesDirectory)
        self.dictionaryCoordinator = dictionaryCoordinator
        let initialMenuState = MenuState(
            config: config,
            permissions: permissionSnapshot(using: permissionService),
            localModels: localModelStates(paths: paths),
            autostartEnabled: Autostart.isEnabled(),
            pendingSuggestionCount: Self.pendingSuggestionCount(config),
            dataMode: paths.mode
        )
        menuState = initialMenuState

        log("Click-n-speak (Swift) starting — schema v\(config.schemaVersion), lang \(i18n.lang)")

        let menuCtrl = MenuBarController(
            config: config,
            i18n: i18n,
            resources: resources,
            paths: paths,
            permissionService: permissionService,
            phraseHistory: phraseHistory,
            dictionaryCoordinator: dictionaryCoordinator,
            initialState: initialMenuState,
            log: log
        )
        let downloader = ModelDownloader(paths: paths, log: log)
        menuCtrl.modelDownloader = downloader
        menuController = menuCtrl
        self.modelDownloader = downloader

        let scheduler = MaintenanceScheduler(
            onFlush: { [weak dictionaryCoordinator] in
                do { try dictionaryCoordinator?.flushIfNeeded() }
                catch { log("Dictionary flush failed: \(error.localizedDescription)") }
            },
            onMaintenance: { [weak dictionaryCoordinator] in
                dictionaryCoordinator?.runDailyMaintenanceIfDue()
            }
        )
        scheduler.start()
        self.scheduler = scheduler

        let transcriberRouter = TranscriberRouter()
        let editorRouter = AiEditorRouter()

        let chunking = ChunkingConfig(
            silenceDuration: config.raw["silence_duration"]?.doubleValue ?? 1.0,
            targetSpeechDuration: config.raw["target_speech_duration"]?.doubleValue ?? 4.0,
            maxSpeechDuration: config.raw["max_speech_duration"]?.doubleValue ?? 8.0,
            minSpeechDuration: config.raw["min_speech_duration"]?.doubleValue ?? 1.0
        )
        let panel = PreviewPanel(resources: resources, i18n: i18n, log: log)
        let sessionRef = SessionBox()
        let recorder = AudioRecorder(
            config: chunking,
            log: log,
            onFatalError: { [sessionRef] in
                Task { @MainActor in sessionRef.controller?.handleRecorderFatalError() }
            }
        )

        let session = SessionController(
            config: config,
            strings: Self.sessionStrings(i18n),
            transcriber: transcriberRouter,
            aiEditor: editorRouter,
            recorder: recorder,
            panel: panel,
            delivery: SystemTextDelivery(log: log),
            frontmost: WorkspaceFrontmostProvider(),
            phraseHistory: phraseHistory,
            dictionaryCoordinator: dictionaryCoordinator,
            log: log,
            onConfigChanged: { [weak self] updated in
                Task { @MainActor in self?.runtimeCoordinator?.requestConfiguration(updated) }
            },
            onBeforeTranscriberReload: { [weak dictionaryCoordinator] in
                do { try dictionaryCoordinator?.flushIfNeeded() }
                catch { log("Pre-reload dictionary flush failed: \(error.localizedDescription)") }
            },
            runtimeDescriptorProvider: {
                RuntimeDescriptor(
                    transcriber: transcriberRouter.currentDescriptorSnapshot,
                    aiEditor: editorRouter.currentDescriptorSnapshot
                )
            },
            onStateChanged: { [weak self] state in
                self?.updateMenuSessionState(state)
            }
        )

        menuCtrl.onTranscribeFileAction = { url, refine, progress in
            await session.transcribeFile(url: url, refine: refine, progress: progress)
        }
        menuCtrl.onCancelFileTranscription = { session.cancelFileTranscription() }

        sessionRef.controller = session
        self.session = session
        configureWarmupLifecycle(for: session)

        let modelOverride = ProcessInfo.processInfo.environment["CNS_WHISPER_MODEL"]
            .map { URL(fileURLWithPath: $0) }
        let editorModelOverride = ProcessInfo.processInfo.environment["CNS_QWEN_MODEL_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let runtimeFactory = RuntimeServiceFactory(
            paths: paths,
            localModelOverride: modelOverride,
            localEditorModelOverride: editorModelOverride,
            log: log
        )
        let runtimeCoordinator = AppRuntimeCoordinator(
            initialConfig: config,
            transcriberRouter: transcriberRouter,
            editorRouter: editorRouter,
            factory: runtimeFactory,
            session: session,
            configURL: paths.configFile,
            log: log
        )
        runtimeCoordinator.onConfigActivated = { [weak self] updated in
            self?.dictionaryCoordinator?.adoptConfiguration(updated)
            self?.updateDesiredMenuConfig(updated)
        }
        runtimeCoordinator.onStateChanged = { [weak self] state in
            self?.updateMenuRuntimeState(state)
            if case .ready = state { self?.startHotkeyIfAllowed() }
            if case let .degraded(active, _, _, _) = state,
               active?.transcriber.readiness == .ready {
                self?.startHotkeyIfAllowed()
            }
        }
        self.runtimeCoordinator = runtimeCoordinator

        dictionaryCoordinator.onSnapshotChanged = { [weak self] updated, invalidations in
            guard let self else { return }
            if invalidations.contains(.config) {
                self.runtimeCoordinator?.updateDictionarySnapshot(updated)
                self.updateDesiredMenuConfig(self.runtimeCoordinator?.desiredConfiguration ?? updated)
            }
            if invalidations.contains(.history) {
                self.menuController?.refreshHistory(reset: true)
            }
        }
        dictionaryCoordinator.onNotification = { [weak notificationService] notification in
            notificationService?.deliver(
                title: i18n.t(notification.titleKey),
                body: i18n.t(notification.bodyKey)
            )
        }
        dictionaryCoordinator.startPromptWatching()

        menuCtrl.onConfigChanged = { [weak self, weak runtimeCoordinator] updated in
            runtimeCoordinator?.requestConfiguration(updated)
            self?.updateDesiredMenuConfig(runtimeCoordinator?.desiredConfiguration ?? updated)
        }
        menuCtrl.onConfigurationReloaded = { [weak runtimeCoordinator] updated in
            runtimeCoordinator?.adoptPersistedConfiguration(updated)
        }
        menuCtrl.onCredentialsChanged = { [weak runtimeCoordinator] in
            runtimeCoordinator?.revalidateDesiredConfiguration()
        }
        menuCtrl.onModelDownloadCompleted = { [weak runtimeCoordinator] in
            runtimeCoordinator?.revalidateDesiredConfiguration()
        }
        menuCtrl.onPermissionRefreshRequested = { [weak self] in
            self?.refreshMenuPermissions()
        }
        menuCtrl.onDownloadStateChanged = { [weak self] download in
            self?.updateMenuDownloadState(download)
        }
        menuCtrl.onHistorySnapshotChanged = { [weak self] history in
            self?.mutateMenuState { $0.history = history }
        }
        menuCtrl.onLocalModelsChanged = { [weak self] in
            guard let self else { return }
            let models = self.localModelStates(paths: paths)
            self.mutateMenuState { $0.localModels = models }
        }
        menuCtrl.onRuntimeRecoveryRequested = { [weak runtimeCoordinator] action in
            switch action {
            case .retry:
                runtimeCoordinator?.revalidateDesiredConfiguration()
            case .keepPreviousRuntime:
                runtimeCoordinator?.keepPreviousRuntime()
            default:
                break
            }
        }
        menuCtrl.refreshHistory(reset: true)

        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuPermissions() }
        }

        let hotkey = HotkeyManager { [weak session] in session?.toggle() }
        self.hotkey = hotkey

        let launchCoordinator = AppLaunchCoordinator(
            paths: paths,
            i18n: i18n,
            permissions: permissionService,
            log: log
        )
        self.launchCoordinator = launchCoordinator
        menuCtrl.onSetupRequested = { [weak self] in
            self?.retryPermissionSetup()
        }

        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let updated = await launchCoordinator.run(config: config)
            self.updateDesiredMenuConfig(updated)
            await runtimeCoordinator.activateInitial(updated)
            do {
                try AppUpdater.acknowledgeSuccessfulLaunch(paths: paths)
            } catch {
                log("Update launch acknowledgement failed: \(error.localizedDescription)")
            }
            self.startHotkeyIfAllowed(log: log)
            self.menuController?.checkAndDownloadLocalModelIfNeeded()
            do {
                try await dictionaryCoordinator.runPromptAnalysis(onDemand: true)
            } catch {
                log("Startup prompt analysis failed: \(error.localizedDescription)")
            }
            self.menuController?.presentPendingSuggestionsIfNeeded()
        }

        // Background Update Check
        Task { await self.checkUpdatesInBackground(log: log) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.checkUpdatesInBackground(log: log) }
        }
    }

    /// Dictionary bootstrap may persist policy decisions during initialization.
    /// Its resulting snapshot must be the sole startup config used by every
    /// downstream coordinator, otherwise runtime activation can overwrite those
    /// decisions with the stale value originally loaded from disk.
    static func prepareDictionaryConfiguration(
        config: Config,
        paths: Paths,
        phraseHistory: any PhraseHistoryProviding,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> (coordinator: DictionaryCoordinator, config: Config) {
        let coordinator = DictionaryCoordinator(
            config: config,
            paths: paths,
            phraseHistory: phraseHistory,
            log: log
        )
        return (coordinator, coordinator.snapshot)
    }

    private func checkUpdatesInBackground(log: @escaping @Sendable (String) -> Void) async {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        do {
            if let update = try await UpdateChecker.check(currentVersion: currentVersion) {
                log("Background update check: version \(update.version) is available.")
                await MainActor.run { [weak self] in
                    self?.mutateMenuState { $0.updateAvailableVersion = update.version }
                }
            } else {
                await MainActor.run { [weak self] in
                    self?.mutateMenuState { $0.updateAvailableVersion = nil }
                }
            }
        } catch {
            log("Background update check failed: \(error)")
        }
    }

    private func retryPermissionSetup() {
        guard let launchCoordinator else { return }
        Task { @MainActor [weak self] in
            _ = await launchCoordinator.runPermissionSetup(force: true)
            self?.startHotkeyIfAllowed()
        }
    }

    private func startHotkeyIfAllowed(log explicitLog: (@Sendable (String) -> Void)? = nil) {
        let log: @Sendable (String) -> Void = explicitLog ?? { [weak logger] message in
            guard let logger else { return }
            Task { await logger.info(message) }
        }
        guard permissionService?.allPermissionsGranted() == true else {
            log("Hotkey remains disabled until Microphone and Accessibility are granted.")
            return
        }
        guard runtimeCoordinator?.canRecord == true else {
            log("Hotkey remains disabled until a transcription runtime is active.")
            return
        }
        guard !hotkeyStarted, let hotkey else { return }
        hotkeyStarted = hotkey.start()
        log(hotkeyStarted ? "Hotkey registered: Option+Space" : "Hotkey registration failed")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        stopLifecycleSources()

        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await self.session?.shutdown()
            self.dictionaryCoordinator?.stop()
            await self.runtimeCoordinator?.shutdown()
            await self.logger?.info("Click-n-speak shutdown complete")
            self.instanceGuard?.release()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normal termination is drained by `applicationShouldTerminate`. Keep a
        // synchronous fallback for unusual AppKit teardown paths.
        guard !terminationStarted else { return }
        stopLifecycleSources()
        dictionaryCoordinator?.stop()
        instanceGuard?.release()
    }

    private func stopLifecycleSources() {
        launchTask?.cancel()
        keepAliveTimer?.invalidate()
        updateTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
        hotkey?.stop()
        scheduler?.stop()
    }

    private func configureWarmupLifecycle(for session: SessionController) {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak session] _ in
            Task { @MainActor in
                _ = await session?.warmupIfIdle(full: false)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak session] _ in
            Task { @MainActor in
                _ = await session?.warmupIfIdle(full: false)
            }
        }
    }

    private func mutateMenuState(_ mutation: (inout MenuState) -> Void) {
        guard var snapshot = menuState else { return }
        mutation(&snapshot)
        menuState = snapshot
        menuController?.apply(snapshot)
    }

    private func updateDesiredMenuConfig(_ config: Config) {
        mutateMenuState { state in
            state.config = config
            state.runtime.desiredSTTBackend = config.sttBackend
            state.runtime.desiredSTTModel = config.sttBackend == "local"
                ? config.sttModelName
                : (config.raw["stt_cloud_model"]?.stringValue ?? "")
            state.runtime.desiredEditorBackend = config.aiEditorEnabled
                ? config.aiEditorBackend
                : "disabled"
            state.pendingSuggestionCount = Self.pendingSuggestionCount(config)
        }
    }

    private func updateMenuSessionState(_ sessionState: SessionState) {
        let phase: MenuSessionPhase
        switch sessionState {
        case .idle, .popup:
            phase = .idle
        case .starting, .recording:
            phase = .recording
        case .stopping, .processing, .injecting:
            phase = .processing
        case .failed:
            phase = .failed
        }
        mutateMenuState { $0.session = phase }
    }

    private func updateMenuRuntimeState(_ coordinatorState: RuntimeCoordinatorState) {
        mutateMenuState { menu in
            var runtime = menu.runtime
            runtime.userMessage = nil
            runtime.recoveryActions = []
            switch coordinatorState {
            case .uninitialized:
                runtime.phase = .uninitialized
            case let .preparing(desired):
                runtime.phase = .preparing
                Self.applyDesired(desired, to: &runtime)
            case let .ready(active):
                runtime.phase = .ready
                Self.applyActive(active, to: &runtime)
            case let .reconfiguring(active, desired):
                runtime.phase = .reconfiguring
                Self.applyActive(active, to: &runtime)
                Self.applyDesired(desired, to: &runtime)
            case let .degraded(active, desired, message, recovery):
                runtime.phase = .degraded
                runtime.userMessage = message
                runtime.recoveryActions = recovery.compactMap {
                    MenuRuntimeRecoveryAction(rawValue: $0.rawValue)
                }
                if let active { Self.applyActive(active, to: &runtime) }
                Self.applyDesired(desired, to: &runtime)
            case .stopping:
                runtime.phase = .stopping
            }
            menu.runtime = runtime
        }
    }

    private static func applyDesired(
        _ desired: RuntimeSelection,
        to runtime: inout MenuRuntimeSnapshot
    ) {
        runtime.desiredSTTBackend = desired.sttBackend
        runtime.desiredSTTModel = desired.sttModelID
        runtime.desiredEditorBackend = desired.editorBackend
    }

    private static func applyActive(
        _ active: RuntimeDescriptor,
        to runtime: inout MenuRuntimeSnapshot
    ) {
        runtime.activeSTTBackend = active.transcriber.backend
        runtime.activeSTTModel = active.transcriber.modelID
        runtime.activeEditorBackend = active.aiEditor.backend
        runtime.activeEditorModel = active.aiEditor.modelID
    }

    private func refreshMenuPermissions() {
        guard let permissionService else { return }
        let snapshot = permissionSnapshot(using: permissionService)
        mutateMenuState { $0.permissions = snapshot }
    }

    private func permissionSnapshot(
        using service: any PermissionServicing
    ) -> MenuPermissionSnapshot {
        MenuPermissionSnapshot(
            microphone: service.microphoneStatus(),
            accessibilityGranted: service.accessibilityGranted(),
            setupComplete: service.isSetupDone()
        )
    }

    private func updateMenuDownloadState(_ download: MenuDownloadSnapshot) {
        mutateMenuState { state in
            state.download = download
            guard let modelID = download.modelID else { return }
            let affectedIDs: [String]
            if ModelRegistry.aiEditorModel(id: modelID) != nil {
                affectedIDs = [modelID]
            } else {
                affectedIDs = ModelCatalog.whisperModels.compactMap { model in
                    let registryID = ModelRegistry.whisperModelByLegacyID(model.id)?.id
                    return model.id == modelID || registryID == modelID ? model.id : nil
                }
            }
            for affectedID in affectedIDs {
                switch download.phase {
                case .downloading:
                    state.localModels[affectedID] = .downloading
                case .validating:
                    state.localModels[affectedID] = .validating
                case .paused:
                    state.localModels[affectedID] = .paused
                case .failed:
                    state.localModels[affectedID] = .failed
                case .completed:
                    state.localModels[affectedID] = .available
                case .cancelled:
                    state.localModels[affectedID] = .downloadRequired
                case .idle:
                    break
                }
            }
        }
    }

    private func localModelStates(paths: Paths) -> [String: MenuLocalModelState] {
        var states: [String: MenuLocalModelState] = Dictionary(
            uniqueKeysWithValues: ModelCatalog.whisperModels.map { model in
                let available = ModelRegistry.whisperModelByLegacyID(model.id)
                    .map { ModelManager.isDownloaded($0, paths: paths) } ?? false
                return (
                    model.id,
                    available ? MenuLocalModelState.available : .downloadRequired
                )
            }
        )
        for model in ModelRegistry.aiEditorModels {
            states[model.id] = ModelManager.isDownloaded(model, paths: paths)
                ? .available
                : .downloadRequired
        }
        return states
    }

    private static func pendingSuggestionCount(_ config: Config) -> Int {
        guard let object = config.raw["pending_suggestions"]?.objectValue else { return 0 }
        return object.keys.reduce(0) { total, key in
            total + (object[key]?.arrayValue?.count ?? 0)
        }
    }

    /// User-visible session strings, resolved once from the loaded locale.
    private static func sessionStrings(_ i18n: I18n) -> SessionStrings {
        SessionStrings(
            recording: i18n.t("hud.recording_title"),
            transcribing: i18n.t("hud.transcribing_title"),
            stillWorking: i18n.t("hud.still_working_title"),
            ready: i18n.t("hud.ready_title"),
            popupTitle: i18n.t("popup.title_with_hotkey"),
            transcriptionInstruction: i18n.t("hud.transcription_instruction"),
            noSpeech: i18n.t("notify.no_speech_title"),
            recordError: i18n.t("notify.record_error_title"),
            transcriptionError: i18n.t("notify.transcription_error_title"),
            transcriptionTimeout: i18n.t("notify.transcription_timeout_title"),
            toasts: DictionaryToasts(
                addedTemplate: i18n.t("toast.added"),
                invalidTerm: i18n.t("toast.invalid_term"),
                alreadyExists: i18n.t("toast.exists")
            )
        )
    }

    private func activateExistingInstance() {
        let bundleID = "com.sergej.clicknspeak"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.first?.activate()
    }
}

/// Lets the recorder's fatal-error callback reach a controller that does not
/// exist yet when the recorder is constructed.
@MainActor
final class SessionBox {
    weak var controller: SessionController?
}
