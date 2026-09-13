import AppKit
import CNSAudio
import CNSCore
import CNSDictionary
import CNSEditors
import CNSInput
import CNSSession
import CNSTranscription
import CNSUI

enum AppTerminationDrainOutcome: Equatable {
    case completed
    case sessionTimedOut([SessionShutdownActivity])
    case dictionaryFailed
}

/// Composition root: wires paths, config, i18n, logging and the menu bar
/// together. Mirrors the startup sequence in `main.py` (instance lock →
/// config load → i18n → coordinators → menu/runtime/session activation).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths: Paths
    private let recoveryPresenter: (ConfigRecoveryCoordinator) -> Config?
    private let restartCoordinator: AppRestartCoordinator
    private var instanceGuard: SingleInstanceGuard?
    private var menuController: MenuBarController?
    private var modelDownloader: ModelDownloader?
    private var scheduler: MaintenanceScheduler?
    private var logger: FileLogger?
    private var session: SessionController?
    var hotkeyRegistrar: (@MainActor () -> Bool)?
    private var hotkey: HotkeyManager?
    var permissionService: PermissionServicing?
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
    private var restartTerminationRequested = false
    private var restartPreparationTask: Task<Void, Never>?
    private var shutdownNotification: (title: String, body: String)?
    private var restartFailureStrings: (
        title: String,
        helperMissing: String,
        helperNotReady: String,
        generic: String,
        ok: String
    )?
    private var hotkeyFailedNotification: (title: String, body: String)?
    private var languageChangeNotification: (title: String, body: String)?
    private var interfaceLanguage = "en"
    private var menuState: MenuState?
    private var updateLaunchReported = false

    init(
        paths: Paths = .resolveDefault(),
        recoveryPresenter: @escaping (ConfigRecoveryCoordinator) -> Config? = { $0.present() },
        restartCoordinator: AppRestartCoordinator? = nil
    ) {
        self.paths = paths
        self.recoveryPresenter = recoveryPresenter
        let applicationURL = Bundle.main.bundleURL
        self.restartCoordinator = restartCoordinator ?? AppRestartCoordinator(
            paths: paths,
            applicationURL: applicationURL,
            helperURL: applicationURL.appendingPathComponent("Contents/MacOS/CNSRestartHelper")
        )
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
        RestartTicketStore.cleanupCompleted(in: paths.restartDirectory)

        let logger = FileLogger(fileURL: paths.logFile)
        self.logger = logger
        RuntimeTelemetry.configure(sink: FileRuntimeTelemetrySink(logger: logger))
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
        interfaceLanguage = i18n.lang
        shutdownNotification = (
            i18n.t("notify.shutdown_timeout_title"),
            i18n.t("notify.shutdown_timeout_body")
        )
        restartFailureStrings = (
            i18n.t("dialog.restart_failed_title"),
            i18n.t("dialog.restart_helper_missing"),
            i18n.t("dialog.restart_helper_not_ready"),
            i18n.t("dialog.restart_failed_body"),
            i18n.t("btn.ok")
        )
        hotkeyFailedNotification = (
            i18n.t("notify.hotkey_failed_title"),
            i18n.t("notify.hotkey_failed_body")
        )
        languageChangeNotification = (
            i18n.t("notify.language_changed_title"),
            i18n.t("notify.language_changed_body")
        )
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
        menuCtrl.onRestartRequested = { [weak self] in self?.requestRestart() }
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
            delivery: SystemTextDelivery(
                notify: { [weak notificationService] title, _, body in
                    Task { @MainActor in
                        notificationService?.deliver(title: title, body: body)
                    }
                },
                log: log,
                strings: Self.textDeliveryStrings(i18n)
            ),
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
        connectConfiguration(dictionary: dictionaryCoordinator, runtime: runtimeCoordinator, menu: menuCtrl)
        dictionaryCoordinator.onNotification = { [weak notificationService] notification in
            notificationService?.deliver(
                title: i18n.t(notification.titleKey),
                body: i18n.t(notification.bodyKey)
            )
        }
        dictionaryCoordinator.startPromptWatching()

        menuCtrl.onCredentialsChanged = { [weak runtimeCoordinator] provider in
            runtimeCoordinator?.revalidateDesiredConfiguration(
                reason: .credentials(provider: provider)
            )
        }
        menuCtrl.onModelDownloadCompleted = { [weak runtimeCoordinator] modelID in
            runtimeCoordinator?.revalidateDesiredConfiguration(reason: .model(id: modelID))
        }
        menuCtrl.onPermissionRefreshRequested = { [weak self] in
            self?.refreshMenuPermissions()
        }
        menuCtrl.onDownloadStateChanged = { [weak self] download in
            self?.updateMenuDownloadState(download)
        }
        menuCtrl.onLocalModelsChanged = { [weak self] in
            guard let self else { return }
            let models = self.localModelStates(paths: paths)
            self.mutateMenuState { $0.localModels = models }
        }
        menuCtrl.onRuntimeRecoveryRequested = { [weak runtimeCoordinator] action in
            switch action.kind {
            case .retry:
                runtimeCoordinator?.revalidateDesiredConfiguration(reason: .retry)
            case .keepPreviousRuntime:
                runtimeCoordinator?.keepPreviousRuntime(generation: action.generation)
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
            let setupPending = !permissionService.isSetupDone()
                || !permissionService.allPermissionsGranted()
                || !config.languagePickerDone
            if setupPending {
                await self.reportUpdateLaunchIfAllowed(
                    setupPending: true,
                    runtimeCanRecord: false,
                    log: log
                )
            }
            let selected = await launchCoordinator.run(config: config)
            var updated = config
            if selected != config {
                do {
                    let previousPrimary = dictionaryCoordinator.snapshot.primaryLanguage
                    try dictionaryCoordinator.applyLanguageSettings(selected)
                    updated = dictionaryCoordinator.snapshot
                    self.notifyInterfaceLanguageRestartIfNeeded(
                        previousPrimary: previousPrimary,
                        updated: updated
                    )
                } catch {
                    log("Failed to save language selection: \(error.localizedDescription)")
                    updated = dictionaryCoordinator.snapshot
                }
            }
            self.updateDesiredMenuConfig(updated)
            await runtimeCoordinator.activateInitial(updated)
            let setupStillPending = !permissionService.isSetupDone()
                || !permissionService.allPermissionsGranted()
                || !updated.languagePickerDone
            await self.reportUpdateLaunchIfAllowed(
                setupPending: setupStillPending,
                runtimeCanRecord: runtimeCoordinator.canRecord,
                log: log
            )
            self.reconcileHotkeyAvailability(log: log)
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

    private func reportUpdateLaunchIfAllowed(
        setupPending: Bool,
        runtimeCanRecord: Bool,
        log: @escaping @Sendable (String) -> Void
    ) async {
        guard !updateLaunchReported,
              let status = UpdateLaunchReadinessPolicy.status(
                  configBootstrapped: true,
                  appRunLoopReady: true,
                  instanceLockHeld: instanceGuard != nil,
                  setupPending: setupPending,
                  runtimeCanRecord: runtimeCanRecord
              ) else { return }
        do {
            if AppUpdater.hasUpdateLaunchArguments() {
                try await AppUpdater.acknowledgeSuccessfulLaunch(paths: paths, status: status)
            } else {
                try await AppUpdater.recoverInterruptedTransactions(paths: paths, status: status)
            }
            updateLaunchReported = true
        } catch {
            log("Update launch acknowledgement failed: \(error.localizedDescription)")
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
            self?.reconcileHotkeyAvailability()
        }
    }

    @MainActor
    func shouldStartHotkey(
        permissionsGranted: Bool,
        runtimeCanRecord: Bool,
        alreadyStarted: Bool,
        terminating: Bool
    ) -> Bool {
        permissionsGranted && runtimeCanRecord && !alreadyStarted && !terminating
    }

    func reconcileHotkeyAvailability(log explicitLog: (@Sendable (String) -> Void)? = nil) {
        let log: @Sendable (String) -> Void = explicitLog ?? { [weak logger] message in
            guard let logger else { return }
            Task { await logger.info(message) }
        }
        let granted = permissionService?.allPermissionsGranted() == true
        let canRecord = runtimeCoordinator?.canRecord == true
        
        guard shouldStartHotkey(
            permissionsGranted: granted,
            runtimeCanRecord: canRecord,
            alreadyStarted: hotkeyStarted,
            terminating: terminationStarted
        ) else {
            if !granted {
                log("Hotkey remains disabled until Microphone and Accessibility are granted.")
            } else if !canRecord {
                log("Hotkey remains disabled until a transcription runtime is active.")
            }
            return
        }
        
        let registrar = hotkeyRegistrar ?? { [weak hotkey] in hotkey?.start() ?? false }
        let success = registrar()
        if success {
            hotkeyStarted = true
            log("Hotkey registered: Option+Space")
        } else {
            log("Hotkey registration failed")
            if let notification = hotkeyFailedNotification {
                notificationService?.deliver(title: notification.title, body: notification.body)
            }
        }
    }

    private func requestRestart() {
        guard !terminationStarted, restartPreparationTask == nil,
              !restartCoordinator.isPending else { return }
        restartPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.restartPreparationTask = nil }
            do {
                try await self.restartCoordinator.prepare()
                guard !self.terminationStarted else {
                    self.restartCoordinator.cancel()
                    return
                }
                self.restartTerminationRequested = true
                NSApp.terminate(nil)
            } catch {
                self.presentRestartFailure(error)
            }
        }
    }

    private func presentRestartFailure(_ error: Error) {
        let strings = restartFailureStrings
        let alert = NSAlert()
        alert.messageText = strings?.title ?? "Restart failed"
        switch error {
        case AppRestartError.helperMissing:
            alert.informativeText = strings?.helperMissing ?? "Restart helper is unavailable."
        case AppRestartError.helperNotReady, AppRestartError.parentObservationFailed:
            alert.informativeText = strings?.helperNotReady ?? "Restart helper did not become ready."
        default:
            alert.informativeText = strings?.generic ?? "Click-n-speak could not restart."
        }
        alert.addButton(withTitle: strings?.ok ?? "OK")
        alert.runModal()
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
            let outcome = await Self.drainForTermination(
                shutdownSession: { [weak self] in
                    await self?.session?.shutdown() ?? SessionShutdownOutcome()
                },
                drainDictionary: { [weak self] in
                    try await self?.dictionaryCoordinator?.drainAndStop()
                },
                shutdownRuntime: { [weak self] in
                    await self?.runtimeCoordinator?.shutdown()
                },
                drainTelemetry: {
                    await RuntimeTelemetry.drain()
                }
            )
            do {
                let accepted = try Self.completeTermination(
                    outcome: outcome,
                    restart: self.restartCoordinator,
                    restartRequested: self.restartTerminationRequested,
                    releaseLock: { self.instanceGuard?.release() }
                )
                guard accepted else {
                    await self.logger?.info("Click-n-speak shutdown paused because owned work did not drain")
                    if let notification = self.shutdownNotification {
                        self.notificationService?.deliver(title: notification.title, body: notification.body)
                    }
                    self.restartTerminationRequested = false
                    self.terminationStarted = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                await self.logger?.info("Click-n-speak shutdown complete")
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                await self.logger?.info("Restart authorization failed before application exit")
                self.presentRestartFailure(error)
                self.restartTerminationRequested = false
                self.terminationStarted = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    static func completeTermination(
        outcome: AppTerminationDrainOutcome,
        restart: AppRestartCoordinator?,
        restartRequested: Bool,
        releaseLock: () -> Void
    ) throws -> Bool {
        guard outcome == .completed else {
            restart?.cancel()
            return false
        }
        if restartRequested {
            guard let restart else { throw AppRestartError.invalidTicket }
            do {
                try restart.authorizeAfterDrain()
            } catch {
                restart.cancel()
                throw error
            }
        } else {
            restart?.cancel()
        }
        releaseLock()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normal termination is drained by `applicationShouldTerminate`. Keep a
        // synchronous fallback for unusual AppKit teardown paths. The OS releases
        // the instance lock on process exit; do not acknowledge undrained work.
        guard !terminationStarted else { return }
        stopLifecycleSources()
        dictionaryCoordinator?.stop()
    }

    static func drainForTermination(
        shutdownSession: () async -> SessionShutdownOutcome,
        drainDictionary: () async throws -> Void,
        shutdownRuntime: () async -> Void,
        drainTelemetry: () async -> Void = { await RuntimeTelemetry.drain() }
    ) async -> AppTerminationDrainOutcome {
        let sessionOutcome = await shutdownSession()
        guard sessionOutcome.succeeded else {
            return .sessionTimedOut(sessionOutcome.pendingActivities)
        }
        do {
            try await drainDictionary()
        } catch {
            return .dictionaryFailed
        }
        await shutdownRuntime()
        await drainTelemetry()
        return .completed
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

    /// Connect configuration ownership and menu projections independently of
    /// permission setup, inference preparation, and other launch side effects.
    func connectConfiguration(
        dictionary dictionaryCoordinator: DictionaryCoordinator,
        runtime runtimeCoordinator: AppRuntimeCoordinator,
        menu menuCtrl: MenuBarController
    ) {
        self.dictionaryCoordinator = dictionaryCoordinator
        self.runtimeCoordinator = runtimeCoordinator
        self.menuController = menuCtrl
        self.menuState = menuCtrl.state
        runtimeCoordinator.onConfigActivated = { [weak self] updated in
            self?.dictionaryCoordinator?.adoptConfiguration(updated)
            self?.updateDesiredMenuConfig(updated)
        }
        runtimeCoordinator.onStateChanged = { [weak self] state in
            self?.updateMenuRuntimeState(state)
            if case .ready = state { self?.reconcileHotkeyAvailability() }
            if case let .degraded(active, _, _, _) = state,
               active?.transcriber.readiness == .ready {
                self?.reconcileHotkeyAvailability()
            }
        }

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
        menuCtrl.onConfigChanged = { [weak self, weak runtimeCoordinator] updated in
            runtimeCoordinator?.requestConfiguration(updated)
            self?.updateDesiredMenuConfig(runtimeCoordinator?.desiredConfiguration ?? updated)
        }
        menuCtrl.onLanguageSettingsChanged = { [weak self, weak dictionaryCoordinator] settings in
            guard let self, let dictionaryCoordinator else { return }
            let previousPrimary = dictionaryCoordinator.snapshot.primaryLanguage
            do {
                try dictionaryCoordinator.applyLanguageSettings(settings)
                self.notifyInterfaceLanguageRestartIfNeeded(
                    previousPrimary: previousPrimary,
                    updated: dictionaryCoordinator.snapshot
                )
            } catch {
                self.updateDesiredMenuConfig(dictionaryCoordinator.snapshot)
                if let logger = self.logger {
                    Task { await logger.info(
                        "Failed to save language settings: \(error.localizedDescription)"
                    ) }
                }
            }
        }
        menuCtrl.onConfigurationReloaded = { [weak self, weak runtimeCoordinator, weak dictionaryCoordinator] updated in
            guard let self, let dictionaryCoordinator else { return }
            let previousPrimary = dictionaryCoordinator.snapshot.primaryLanguage
            try dictionaryCoordinator.adoptPersistedConfiguration(updated)
            runtimeCoordinator?.adoptPersistedConfiguration(dictionaryCoordinator.snapshot)
            self.notifyInterfaceLanguageRestartIfNeeded(
                previousPrimary: previousPrimary,
                updated: dictionaryCoordinator.snapshot
            )
        }
        menuCtrl.onHistorySnapshotChanged = { [weak self] history in
            self?.mutateMenuState { $0.history = history }
        }
    }

    private func notifyInterfaceLanguageRestartIfNeeded(
        previousPrimary: String,
        updated: Config
    ) {
        guard previousPrimary != updated.primaryLanguage,
              Self.interfaceLanguageRequiresRestart(
                  currentLanguage: interfaceLanguage,
                  updated: updated
              ),
              let notification = languageChangeNotification else { return }
        notificationService?.deliver(title: notification.title, body: notification.body)
    }

    static func interfaceLanguageRequiresRestart(
        currentLanguage: String,
        updated: Config
    ) -> Bool {
        LanguageCode.normalize(currentLanguage) != updated.primaryLanguage
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
        case .fileProcessing:
            phase = .fileProcessing
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
                runtime.recoveryActions = recovery
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
            incompleteWarning: i18n.t("preview.incomplete_warning"),
            deliveryRecovery: i18n.t("preview.delivery_recovery"),
            toasts: DictionaryToasts(
                addedTemplate: i18n.t("toast.added"),
                invalidTerm: i18n.t("toast.invalid_term"),
                alreadyExists: i18n.t("toast.exists")
            )
        )
    }

    private static func textDeliveryStrings(_ i18n: I18n) -> TextDeliveryStrings {
        TextDeliveryStrings(
            textCopiedTitle: i18n.t("notify.delivery_copied_title"),
            targetUnavailableBody: i18n.t("notify.delivery_target_unavailable_body"),
            focusTimedOutBody: i18n.t("notify.delivery_focus_timeout_body"),
            injection: TextInjectionStrings(
                accessibilityTitle: i18n.t("notify.delivery_accessibility_title"),
                accessibilityBody: i18n.t("notify.delivery_accessibility_body"),
                failureTitle: i18n.t("notify.delivery_failed_title"),
                failureBody: i18n.t("notify.delivery_failed_body")
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
