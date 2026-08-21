import AppKit
import CNSAudio
import CNSCore
import CNSDictionary
import CNSInput
import CNSSession
import CNSTranscription
import CNSUI

/// Composition root: wires paths, config, i18n, logging and the menu bar
/// together. Mirrors the startup sequence in `main.py` (instance lock →
/// config load → i18n → menu), minus the transcriber/recorder wiring that
/// arrives in later phases.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceGuard: SingleInstanceGuard?
    private var menuController: MenuBarController?
    private var modelDownloader: ModelDownloader?
    private var scheduler: MaintenanceScheduler?
    private var logger: FileLogger?
    private var session: SessionController?
    private var hotkey: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = Paths.resolveDefault()
        try? paths.ensureDataDirectory()

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
        let config = Config.load(from: paths.configFile)
        // Persist a migrated default on first run (Python copies config.example.json).
        if !configExisted {
            try? config.saveAtomically(to: paths.configFile)
        }

        let resources = AppResources.resolve()
        let lang = config.languagePickerDone ? config.primaryLanguage : config.primaryLanguage
        let i18n = I18n.load(lang, localesDirectory: resources.localesDirectory)

        log("Click-n-speak (Swift) starting — schema v\(config.schemaVersion), lang \(i18n.lang)")

        let menuCtrl = MenuBarController(config: config, i18n: i18n, resources: resources, paths: paths, log: log)
        let downloader = ModelDownloader(paths: paths, log: log)
        menuCtrl.modelDownloader = downloader
        menuController = menuCtrl
        self.modelDownloader = downloader

        let scheduler = MaintenanceScheduler(
            onFlush: { log("maintenance: flush tick (not implemented)") },
            onMaintenance: { log("maintenance: daily tick (not implemented)") }
        )
        scheduler.start()
        self.scheduler = scheduler

        // Phase 2 pipeline: hotkey → recorder → transcriber → HUD.
        // Use the real whisper.cpp engine when its model is present (env override
        // or the app data dir); fall back to the stub so the app still runs
        // before the model download phase lands.
        let modelURL: URL = {
            if let override = ProcessInfo.processInfo.environment["CNS_WHISPER_MODEL"] {
                return URL(fileURLWithPath: override)
            }
            return paths.whisperModelFile
        }()
        let transcriber: any Transcribing
        if FileManager.default.fileExists(atPath: modelURL.path) {
            log("Using whisper.cpp engine: \(modelURL.lastPathComponent)")
            transcriber = GuardedTranscriber(wrapping: WhisperCppTranscriber(modelURL: modelURL))
        } else {
            log("Whisper model not found at \(modelURL.path) — using stub transcriber")
            transcriber = GuardedTranscriber(wrapping: StubTranscriber())
        }
        let chunking = ChunkingConfig(
            silenceDuration: config.raw["silence_duration"]?.doubleValue ?? 1.0,
            targetSpeechDuration: config.raw["target_speech_duration"]?.doubleValue ?? 3.0,
            maxSpeechDuration: config.raw["max_speech_duration"]?.doubleValue ?? 8.0,
            minSpeechDuration: config.raw["min_speech_duration"]?.doubleValue ?? 0.5
        )
        let panel = PreviewPanel(resources: resources, log: log)
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
            transcriber: transcriber,
            recorder: recorder,
            panel: panel,
            delivery: SystemTextDelivery(log: log),
            frontmost: WorkspaceFrontmostProvider(),
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile, log: log),
            datasetLogger: DatasetLogger(fileURL: paths.datasetFile, log: log),
            log: log,
            onConfigChanged: { updated in
                try? updated.saveAtomically(to: paths.configFile)
            }
        )
        sessionRef.controller = session
        self.session = session

        let hotkey = HotkeyManager { [weak session] in session?.toggle() }
        if hotkey.start() {
            log("Hotkey registered: Option+Space")
        } else {
            log("Hotkey registration failed")
        }
        self.hotkey = hotkey
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        scheduler?.stop()
        instanceGuard?.release()
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
