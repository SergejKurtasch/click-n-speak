import CNSAudio
import CNSCore
import CNSDictionary
import CNSTranscription
import CNSUI
import CryptoKit
import Foundation

/// User-visible strings for one dictation cycle, resolved by the caller from
/// `I18n` so the controller itself stays free of localisation lookups.
public struct SessionStrings: Sendable {
    public var recording: String
    public var transcribing: String
    public var stillWorking: String
    public var ready: String
    public var popupTitle: String
    public var transcriptionInstruction: String
    public var noSpeech: String
    public var recordError: String
    public var toasts: DictionaryToasts

    public init(
        recording: String = "Recording…",
        transcribing: String = "Transcribing…",
        stillWorking: String = "Still working…",
        ready: String = "Ready",
        popupTitle: String = "Edit and press Enter",
        transcriptionInstruction: String = "",
        noSpeech: String = "No speech detected",
        recordError: String = "Recording error",
        toasts: DictionaryToasts = DictionaryToasts()
    ) {
        self.recording = recording
        self.transcribing = transcribing
        self.stillWorking = stillWorking
        self.ready = ready
        self.popupTitle = popupTitle
        self.transcriptionInstruction = transcriptionInstruction
        self.noSpeech = noSpeech
        self.recordError = recordError
        self.toasts = toasts
    }
}

/// The dictation state machine: hotkey → record → transcribe → edit popup →
/// inject. Ported from the session half of `SVoiceRecApp` in `app.py`
/// (`toggle_recording`, `start_recording`, `stop_recording_and_process`,
/// `chunk_worker`, `process_chunk`, `_do_finish_cleanup`, `_watch_overdue_worker`,
/// and the confirm/cancel callbacks).
///
/// Everything lives on the main actor: the Python `_main_thread_queue` hops exist
/// only because AppKit work was raised from worker threads, and `await` on the
/// transcriber actor keeps the UI responsive without them (§4.2). Audio callbacks
/// arrive off-thread and enter through an `AsyncStream`.
@MainActor
public final class SessionController {
    /// `TRANSCRIBER_RESTART_AFTER_SESSIONS`.
    public static let reloadAfterSessions = 20
    /// Hotkey debounce, `debounce_interval` in `app.py`.
    public static let debounceInterval: TimeInterval = 0.3
    /// Soft join timeout on the worker; it never clears `isProcessing` (§6 nr. 6).
    public static let workerSoftTimeout: TimeInterval = 30
    /// Trailing space appended to injected text, as in `_run_injection`.
    static let injectionSuffix = " "

    // MARK: - State (names kept from app.py)

    public private(set) var isRecording = false
    public private(set) var isProcessing = false
    public private(set) var sessionId = 0
    public private(set) var completedSessions = 0
    public private(set) var appendToPopup = false
    public private(set) var workerOverdue = false
    public private(set) var previousAppPid: pid_t?
    /// Set when the audio stack died and the app must restart before recording again.
    public private(set) var restartPending = false

    private var transcribedParts: [String] = []
    private var rawChunks: [String] = []
    private var detectedLanguage = ""
    private var lastToggleAt: Date?
    private var sawFinalChunk = false
    /// Session id whose chunk worker has exited; the watchdogs poll this.
    private var finishedWorkerSessionId = 0

    private var chunkContinuation: AsyncStream<SessionChunk>.Continuation?
    private var workerTask: Task<Void, Never>?
    private var overdueWatchdog: Task<Void, Never>?

    // MARK: - Collaborators

    private var config: Config
    private let strings: SessionStrings
    private let transcriber: any Transcribing
    private let recorder: any AudioCapturing
    private let panel: any PopupPresenting
    private let delivery: any TextDelivering
    private let frontmost: any FrontmostAppProviding
    private let phraseHistory: PhraseHistory?
    private let datasetLogger: DatasetLogger?
    private let contextBuilder: ChunkContextBuilder
    private let softTimeout: TimeInterval
    /// Overrides the backlog-derived hard deadline; tests use it to keep runs short.
    private let hardTimeoutOverride: TimeInterval?
    private let log: @Sendable (String) -> Void
    /// Called after the controller mutates config (⌘D), so the owner can persist it.
    private let onConfigChanged: (Config) -> Void

    public init(
        config: Config,
        strings: SessionStrings = SessionStrings(),
        transcriber: any Transcribing,
        recorder: any AudioCapturing,
        panel: any PopupPresenting,
        delivery: any TextDelivering,
        frontmost: any FrontmostAppProviding,
        phraseHistory: PhraseHistory? = nil,
        datasetLogger: DatasetLogger? = nil,
        contextBuilder: ChunkContextBuilder = ChunkContextBuilder(),
        workerSoftTimeout: TimeInterval = SessionController.workerSoftTimeout,
        workerHardTimeout: TimeInterval? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onConfigChanged: @escaping (Config) -> Void = { _ in }
    ) {
        self.config = config
        self.strings = strings
        self.transcriber = transcriber
        self.recorder = recorder
        self.panel = panel
        self.delivery = delivery
        self.frontmost = frontmost
        self.phraseHistory = phraseHistory
        self.datasetLogger = datasetLogger
        self.contextBuilder = contextBuilder
        self.softTimeout = workerSoftTimeout
        self.hardTimeoutOverride = workerHardTimeout
        self.log = log
        self.onConfigChanged = onConfigChanged
    }

    /// Replace the config after an external change (menu edits, prompt file watcher).
    public func updateConfig(_ config: Config) {
        self.config = config
    }

    // MARK: - Hotkey

    /// Hotkey callback. Debounced, and refuses to start while the previous
    /// session is still being processed.
    public func toggle(now: Date = Date()) {
        if let lastToggleAt, now.timeIntervalSince(lastToggleAt) < Self.debounceInterval {
            log("Ignoring hotkey: debounce interval not met.")
            return
        }
        lastToggleAt = now

        if isProcessing {
            log("Still processing previous recording. Please wait.")
            return
        }
        if restartPending {
            log("Ignoring hotkey: app restart in progress.")
            return
        }

        if isRecording {
            beginStop()
        } else {
            beginStart()
        }
    }

    /// The recorder could not tear its stream down; the app must restart before
    /// it records again (`_on_recorder_fatal_error`).
    public func handleRecorderFatalError() {
        restartPending = true
        log("Recorder reported a fatal error; recording is blocked until restart.")
    }

    // MARK: - Start

    private func beginStart() {
        isRecording = true
        sessionId += 1
        let id = sessionId
        transcribedParts = []
        rawChunks = []
        detectedLanguage = ""
        sawFinalChunk = false
        workerOverdue = false
        finishedWorkerSessionId = 0

        // A popup still open means this recording extends it: keep the popup and
        // the app it belongs to, and append the new text (§6 nr. 12).
        appendToPopup = panel.isShowingInteractive
        if appendToPopup {
            log("Popup is open — new recording will append to existing text.")
        } else {
            previousAppPid = frontmost.frontmostPid()
            panel.show(title: strings.recording)
        }

        let (stream, continuation) = AsyncStream<SessionChunk>.makeStream(
            // Never block the audio path — Python uses put_nowait for the same reason.
            bufferingPolicy: .unbounded
        )
        chunkContinuation = continuation
        workerTask = Task { [weak self] in
            await self?.runWorker(stream, sessionId: id)
        }

        let transcriber = self.transcriber
        Task { await transcriber.preWarm() }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(callbacks: self.makeRecorderCallbacks(sessionId: id))
                self.log("Recording started (session \(id))")
            } catch {
                self.log("Failed to start recorder: \(error)")
                self.abortStart(error: error)
            }
        }
    }

    private func makeRecorderCallbacks(sessionId id: Int) -> AudioRecorder.Callbacks {
        let continuation = chunkContinuation
        return AudioRecorder.Callbacks(
            onChunk: { samples in
                continuation?.yield(SessionChunk(audio: samples, isFinal: false, sessionId: id))
            },
            onFinal: { samples in
                if let samples {
                    continuation?.yield(SessionChunk(audio: samples, isFinal: true, sessionId: id))
                }
                continuation?.finish()
            }
        )
    }

    private func abortStart(error: Error) {
        isRecording = false
        chunkContinuation?.finish()
        chunkContinuation = nil
        panel.updateStatus(strings.recordError)
        panel.hide(delay: 2.0)
        if case RecorderError.previousStreamStuck = error {
            restartPending = true
        }
    }

    // MARK: - Stop

    private func beginStop() {
        isRecording = false
        isProcessing = true
        panel.updateStatus(strings.transcribing)

        recorder.stop()          // delivers the final chunk through onFinal…
        chunkContinuation?.finish()  // …and this closes the stream if it did not
        chunkContinuation = nil
        log("Recording stopped; draining chunk queue.")

        let id = sessionId
        Task { [weak self] in
            await self?.superviseWorker(sessionId: id)
        }
    }

    /// Wait for the worker, and if it overruns the soft timeout keep the session
    /// blocked (never clear `isProcessing` here) while a watchdog owns the hard
    /// deadline — invariant 6.
    private func superviseWorker(sessionId id: Int) async {
        if await workerFinishes(sessionId: id, within: softTimeout) { return }
        guard sessionId == id, isProcessing else { return }

        workerOverdue = true
        log("Chunk worker exceeded \(Int(softTimeout))s; keeping the session blocked.")
        panel.updateStatus(strings.stillWorking)
        startOverdueWatchdog(sessionId: id)
    }

    private func startOverdueWatchdog(sessionId id: Int) {
        // Same shape as `_start_overdue_worker_watchdog`: scale with the backlog,
        // but never wait less than 105 s or more than 5 min.
        let pending = max(1, transcribedParts.count + 1)
        let hardTimeout = hardTimeoutOverride
            ?? min(300.0, max(105.0, Double(pending) * 35.0 + 20.0))

        overdueWatchdog?.cancel()
        overdueWatchdog = Task { [weak self] in
            guard let self else { return }
            if await self.workerFinishes(sessionId: id, within: hardTimeout) { return }
            guard self.sessionId == id else { return }

            self.log("Chunk worker exceeded hard timeout (\(Int(hardTimeout))s); aborting the decode.")
            // Release the blocked decode, then drop the model so the next session
            // starts from a clean one. Mirrors the Python child-process restart.
            self.transcriber.abortInFlight()
            let transcriber = self.transcriber
            await transcriber.reload()
        }
    }

    /// Poll until the worker for `id` reports done, or the deadline passes.
    /// Polling rather than awaiting the task: a task group would hold us until
    /// every child returned, which is exactly the wait we are trying to bound.
    private func workerFinishes(sessionId id: Int, within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while finishedWorkerSessionId != id {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - Worker

    private func runWorker(_ stream: AsyncStream<SessionChunk>, sessionId id: Int) async {
        for await chunk in stream {
            await processChunk(chunk, sessionId: id)
        }
        finishedWorkerSessionId = id
        guard sessionId == id else {
            log("Chunk worker for stale session \(id) exiting.")
            return
        }
        workerOverdue = false
        // Stop produced no final chunk (too short, or the recorder never started),
        // but partial chunks may still hold the whole phrase.
        if !sawFinalChunk, isProcessing {
            finalize(sessionId: id)
        }
        finishCleanup()
    }

    private func processChunk(_ chunk: SessionChunk, sessionId id: Int) async {
        let context = await contextBuilder.build(
            instruction: strings.transcriptionInstruction,
            vocabPrompt: config.initialPrompt,
            transcribedParts: transcribedParts,
            tokenCount: { [transcriber] text in await transcriber.tokenCount(text) }
        )
        let request = TranscriptionRequest(
            audio: chunk.audio,
            initialPrompt: context.isEmpty ? nil : context,
            allowedLanguages: allowedLanguages(),
            isFinalChunk: chunk.isFinal
        )

        let result = await transcriber.transcribe(request)

        // The user started a new session while this chunk was decoding; showing
        // its text now would inject stale speech (§6 nr. 11).
        guard sessionId == id else {
            log("Dropping chunk from stale session \(id).")
            return
        }

        if !result.text.isEmpty {
            transcribedParts.append(result.text)
            rawChunks.append(result.text)
            if !result.detectedLanguage.isEmpty { detectedLanguage = result.detectedLanguage }
        }

        if chunk.isFinal {
            sawFinalChunk = true
            finalize(sessionId: id)
        } else if !result.text.isEmpty {
            panel.updateText(ChunkJoiner.join(transcribedParts))
        }
    }

    /// Hand the accumulated text to the user for editing.
    private func finalize(sessionId id: Int) {
        let fullText = ChunkJoiner.join(transcribedParts)
        guard !fullText.isEmpty else {
            log("Nothing recognised in session \(id).")
            appendToPopup = false
            panel.updateStatus(strings.noSpeech)
            panel.hide(delay: 2.0)
            return
        }

        if appendToPopup, panel.isShowingInteractive {
            panel.appendText(fullText)
            appendToPopup = false
            log("Appended \(fullText.count) chars to the open popup.")
            return
        }

        appendToPopup = false
        panel.showInteractive(
            text: fullText,
            title: strings.popupTitle,
            toasts: strings.toasts,
            onConfirm: { [weak self] text in self?.handleConfirm(text) },
            onCancel: { [weak self] in self?.handleCancel() },
            onAddToDictionary: { [weak self] term in
                self?.handleAddToDictionary(term) ?? .alreadyExists
            }
        )
        log("Interactive popup shown for session \(id) (\(fullText.count) chars).")
    }

    private func finishCleanup() {
        isProcessing = false
        panel.updateStatus(strings.ready)
        completedSessions += 1

        if completedSessions % Self.reloadAfterSessions == 0 {
            log("Reloading the model after \(completedSessions) sessions.")
            let transcriber = self.transcriber
            Task { await transcriber.reload() }
        }
    }

    // MARK: - Popup callbacks

    private func handleConfirm(_ userText: String) {
        let raw = rawChunks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = detectedLanguage.isEmpty ? config.primaryLanguage : detectedLanguage
        let pid = previousAppPid

        datasetLogger?.append(
            DatasetRecord(
                rawWhisper: raw,
                userFinal: userText,
                lang: lang,
                promptHash: Self.promptHash(config.initialPrompt),
                userTerms: UserTerms.activeTerms(config, lang: lang)
            )
        )
        guard !userText.isEmpty else {
            log("Confirmed with empty text; nothing to inject.")
            return
        }
        phraseHistory?.append(userText)

        Task { [weak self] in
            guard let self else { return }
            // Let the popup's close finish on the run loop before another app is
            // activated, exactly as the Python 0.2 s pause does.
            try? await Task.sleep(nanoseconds: 200_000_000)
            let delivered = await self.delivery.deliver(userText + Self.injectionSuffix, to: pid)
            self.log("Injection finished: delivered=\(delivered) chars=\(userText.count)")
        }
    }

    private func handleCancel() {
        log("User cancelled the popup; nothing injected.")
    }

    /// ⌘D in the popup: route the term to the language matching its script, then
    /// rebuild the prompt and let the owner persist the config.
    private func handleAddToDictionary(_ term: String) -> AddTermResult {
        let lang = UserTerms.targetLanguage(for: term, config: config)
        guard UserTerms.add(to: &config, lang: lang, term: term, source: .manual) else {
            return .alreadyExists
        }
        config.raw["initial_prompt"] = .string(InitialPromptBuilder().build(config: config.raw))
        onConfigChanged(config)
        log("Added term to dictionary via popup: \(term) -> \(lang)")

        let langName = LanguageCode.displayNames[lang] ?? lang.uppercased()
        return .added(message: "„\(term)“ → \(langName)")
    }

    // MARK: - Helpers

    /// `get_allowed_languages`: primary first, then additional, deduplicated.
    /// Empty means auto-detect — Whisper then gets no language hint at all.
    func allowedLanguages() -> [String] {
        if config.raw["language_auto_detect"]?.isTruthy == true { return [] }
        let primary = config.primaryLanguage
        return [primary] + LanguageCode.dedupeList(config.additionalLanguages, primary: primary)
    }

    /// `hashlib.md5(initial_prompt)[:12]` — a fingerprint of the prompt in effect,
    /// used to correlate dataset rows with dictionary changes.
    static func promptHash(_ prompt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(prompt.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}

/// One audio chunk on its way from the recorder to the transcriber.
struct SessionChunk: Sendable {
    let audio: [Float]
    let isFinal: Bool
    let sessionId: Int
}
