import AppKit
import CNSCore
import CNSInput
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
    private var scheduler: MaintenanceScheduler?
    private var logger: FileLogger?
    private var coordinator: RecordingCoordinator?
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

        menuController = MenuBarController(config: config, i18n: i18n, resources: resources, log: log)

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
        let coordinator = RecordingCoordinator(
            config: config, i18n: i18n, resources: resources,
            transcriber: transcriber, log: log
        )
        self.coordinator = coordinator

        let hotkey = HotkeyManager { [weak coordinator] in coordinator?.toggle() }
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

    private func activateExistingInstance() {
        let bundleID = "com.sergej.clicknspeak"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.first?.activate()
    }
}
