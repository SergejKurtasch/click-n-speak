import CNSCore
import CNSDictionary
import CNSTranscription
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
    public var transcriptionError: String
    public var transcriptionTimeout: String
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
        transcriptionError: String = "Speech recognition failed",
        transcriptionTimeout: String = "Speech recognition timed out",
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
        self.transcriptionError = transcriptionError
        self.transcriptionTimeout = transcriptionTimeout
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

    // MARK: - State

    public private(set) var state: SessionState = .idle
    public var isRecording: Bool {
        switch state {
        case .starting, .recording: true
        default: false
        }
    }
    public var isProcessing: Bool {
        switch state {
        case .stopping, .processing, .fileProcessing: true
        default: false
        }
    }
    public private(set) var sessionId = 0
    public private(set) var completedSessions = 0
    public private(set) var appendToPopup = false
    public private(set) var popupDraft: PopupDraft?
    public var workerOverdue: Bool {
        if case .processing(_, overdue: true) = state { return true }
        return false
    }
    public private(set) var previousAppPid: pid_t?
    /// Set when the audio stack died and the app must restart before recording again.
    public private(set) var restartPending = false
    public private(set) var runtimeAvailable = true
    public private(set) var isShuttingDown = false
    public private(set) var runtimeMutationInProgress = false
    public var isRuntimeIdle: Bool {
        state == .idle
            && !fileJobActive
            && !isShuttingDown
            && !reloadInProgress
            && !runtimeMutationInProgress
            && warmupTask == nil
    }

    private var transcribedParts: [String] = []
    private var rawChunks: [String] = []
    private var detectedLanguage = ""
    private var lastToggleAt: Date?
    private var sawFinalChunk = false
    private var completedOutcomeSessionId: Int?
    private var activeSessionRuntimeDescriptor: RuntimeDescriptor = .unavailable
    private var activeSessionPromptHash = ""
    private var lastTranscriptionError: String?
    private var fileJobActive = false
    private var stopRequestedUptime: TimeInterval?

    private var chunkContinuation: AsyncStream<SessionChunk>.Continuation?
    private var workerTask: Task<Void, Never>?
    private var recorderStartTask: Task<Void, Never>?
    private var overdueWatchdog: Task<Void, Never>?
    private var workerCompletedSessionId: Int?
    private var completedWorkerSessionId: Int?
    private var hardAbortedSessionId: Int?
    private var reloadInProgress = false
    private var pendingPeriodicReload = false
    private var warmupTask: Task<Void, Never>?

    // MARK: - Collaborators

    private var config: Config
    private let strings: SessionStrings
    private let transcriber: any Transcribing
    private let aiEditor: (any AiEditing)?
    private let recorder: any AudioCapturing
    private let panel: any PopupPresenting
    private let delivery: any TextDelivering
    private let frontmost: any FrontmostAppProviding
    private let phraseHistory: (any PhraseHistoryProviding)?
    private let datasetLogger: DatasetLogger?
    private let dictionaryCoordinator: (any DictionaryCoordinating)?
    private let contextBuilder: ChunkContextBuilder
    private let softTimeout: TimeInterval
    /// Overrides the backlog-derived hard deadline; tests use it to keep runs short.
    private let hardTimeoutOverride: TimeInterval?
    private let log: @Sendable (String) -> Void
    /// Called after the controller mutates config (⌘D), so the owner can persist it.
    private let onConfigChanged: (Config) -> Void
    private let onBeforeTranscriberReload: () -> Void
    private let runtimeDescriptorProvider: @Sendable () -> RuntimeDescriptor
    private let onStateChanged: (SessionState) -> Void
    private let onPhraseHistoryChanged: () -> Void

    private var lastRefineResult: RefineResult?
    private var healthMonitor: TranscriberHealthMonitor
    private var restartTranscriberReason: String?
    private var sawFirstDecode = false

    public init(
        config: Config,
        strings: SessionStrings = SessionStrings(),
        transcriber: any Transcribing,
        aiEditor: (any AiEditing)? = nil,
        recorder: any AudioCapturing,
        panel: any PopupPresenting,
        delivery: any TextDelivering,
        frontmost: any FrontmostAppProviding,
        phraseHistory: (any PhraseHistoryProviding)? = nil,
        datasetLogger: DatasetLogger? = nil,
        dictionaryCoordinator: (any DictionaryCoordinating)? = nil,
        contextBuilder: ChunkContextBuilder = ChunkContextBuilder(),
        workerSoftTimeout: TimeInterval = SessionController.workerSoftTimeout,
        workerHardTimeout: TimeInterval? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onConfigChanged: @escaping (Config) -> Void = { _ in },
        onBeforeTranscriberReload: @escaping () -> Void = {},
        runtimeDescriptorProvider: (@Sendable () -> RuntimeDescriptor)? = nil,
        onStateChanged: @escaping (SessionState) -> Void = { _ in },
        onPhraseHistoryChanged: @escaping () -> Void = {}
    ) {
        self.config = config
        self.strings = strings
        self.transcriber = transcriber
        self.aiEditor = aiEditor
        self.recorder = recorder
        self.panel = panel
        self.delivery = delivery
        self.frontmost = frontmost
        self.phraseHistory = phraseHistory
        self.datasetLogger = datasetLogger
        self.dictionaryCoordinator = dictionaryCoordinator
        self.contextBuilder = contextBuilder
        self.softTimeout = workerSoftTimeout
        self.hardTimeoutOverride = workerHardTimeout
        self.log = log
        self.onConfigChanged = onConfigChanged
        self.onBeforeTranscriberReload = onBeforeTranscriberReload
        self.onStateChanged = onStateChanged
        self.onPhraseHistoryChanged = onPhraseHistoryChanged
        self.runtimeDescriptorProvider = runtimeDescriptorProvider ?? {
            RuntimeDescriptor.unavailable
        }
        self.healthMonitor = TranscriberHealthMonitor()
    }

    /// Replace the config after an external change (menu edits, prompt file watcher).
    public func updateConfig(_ config: Config) {
        self.config = config
    }

    public func setRuntimeAvailable(_ available: Bool) {
        runtimeAvailable = available
    }

    /// Atomically reserves the idle session boundary for a runtime commit.
    public func beginRuntimeMutation() -> Bool {
        guard isRuntimeIdle else { return false }
        runtimeMutationInProgress = true
        return true
    }

    /// Releases a runtime reservation. Repeated release is intentionally safe.
    public func endRuntimeMutation() {
        guard runtimeMutationInProgress else { return }
        runtimeMutationInProgress = false
        runDeferredReloadIfIdle()
    }

    public func shutdown() async {
        isShuttingDown = true
        runtimeAvailable = false
        recorderStartTask?.cancel()
        warmupTask?.cancel()
        overdueWatchdog?.cancel()
        await recorder.stop()
        chunkContinuation?.finish()
        chunkContinuation = nil
        workerTask?.cancel()
        panel.hide(delay: 0)
        transition(to: .idle, reason: "shutdown")
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

        guard !isShuttingDown, !fileJobActive, !runtimeMutationInProgress else {
            log("Ignoring hotkey: another session activity owns the runtime.")
            return
        }

        switch state {
        case .starting, .recording:
            beginStop()
        case .idle, .popup:
            guard runtimeAvailable, !restartPending, !reloadInProgress else {
                log("Ignoring hotkey: transcription runtime is unavailable or changing.")
                return
            }
            beginStart()
        case let .failed(recoverable, _):
            guard recoverable, runtimeAvailable, !restartPending, !reloadInProgress else {
                log("Ignoring hotkey: the failed session is not recoverable yet.")
                return
            }
            beginStart()
        case .stopping, .processing, .fileProcessing, .injecting:
            log("Still processing previous activity. Please wait.")
            return
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
        let hotkeyUptime = ProcessInfo.processInfo.systemUptime
        sessionId += 1
        let id = sessionId
        transcribedParts = []
        rawChunks = []
        detectedLanguage = ""
        sawFinalChunk = false
        sawFirstDecode = false
        lastTranscriptionError = nil
        completedOutcomeSessionId = nil
        activeSessionRuntimeDescriptor = runtimeDescriptorProvider()
        activeSessionPromptHash = Self.promptHash(config.initialPrompt)
        // A popup still open means this recording extends it: keep the popup and
        // the app it belongs to, and append the new text (§6 nr. 12).
        appendToPopup = panel.isShowingInteractive && popupDraft != nil
        if appendToPopup {
            previousAppPid = popupDraft?.targetPID
            panel.setDecisionEnabled(false)
            log("Popup is open — new recording will append to existing text.")
        } else {
            previousAppPid = frontmost.frontmostPid()
            popupDraft = PopupDraft(targetPID: previousAppPid)
            panel.show(title: strings.recording)
        }
        stopRequestedUptime = nil
        transition(
            to: .starting(sessionID: id, targetPID: previousAppPid, appendMode: appendToPopup),
            reason: "hotkey_start"
        )
        RuntimeTelemetry.emitRuntimeEvent("session_start", fields: [
            "session_id": id,
            "stt_backend": activeSessionRuntimeDescriptor.transcriber.backend,
            "stt_model": activeSessionRuntimeDescriptor.transcriber.modelID,
            "ai_backend": activeSessionRuntimeDescriptor.aiEditor.backend,
            "ai_model": activeSessionRuntimeDescriptor.aiEditor.modelID ?? "none",
            "hud_latency_ms": (ProcessInfo.processInfo.systemUptime - hotkeyUptime) * 1000,
            "append_mode": appendToPopup
        ])

        let (stream, continuation) = AsyncStream<SessionChunk>.makeStream(
            // Never block the audio path — Python uses put_nowait for the same reason.
            bufferingPolicy: .unbounded
        )
        chunkContinuation = continuation
        workerTask = Task { [weak self] in
            await self?.runWorker(stream, sessionId: id)
        }

        recorderStartTask?.cancel()
        recorderStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(callbacks: self.makeRecorderCallbacks(sessionId: id))
                await self.recorderDidStart(sessionId: id)
            } catch is CancellationError {
                await self.recorderStartWasCancelled(sessionId: id)
            } catch {
                self.log("Failed to start recorder: \(error)")
                await self.abortStart(error: error, sessionId: id)
            }
        }
    }

    private func recorderDidStart(sessionId id: Int) async {
        guard case let .starting(activeID, targetPID, appendMode) = state, activeID == id else {
            log("Recorder start completed for stale/cancelled session \(id); stopping it.")
            await recorder.stop()
            return
        }
        transition(
            to: .recording(sessionID: id, targetPID: targetPID, appendMode: appendMode),
            reason: "recorder_started"
        )
        log("Recording started (session \(id))")
    }

    private func recorderStartWasCancelled(sessionId id: Int) async {
        await recorder.stop()
        guard state.sessionID == id else { return }
        chunkContinuation?.finish()
        chunkContinuation = nil
        if !restoreDraftAfterEmptyAppendIfNeeded() {
            popupDraft = nil
        }
        completeSession(id: id, reason: "start_cancelled", showReady: false)
    }

    private func makeRecorderCallbacks(sessionId id: Int) -> AudioCallbacks {
        let continuation = chunkContinuation
        return AudioCallbacks(
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

    private func abortStart(error: Error, sessionId id: Int) async {
        await recorder.stop()
        guard state.sessionID == id else { return }
        chunkContinuation?.finish()
        chunkContinuation = nil
        let preservedAppend = restoreDraftAfterEmptyAppendIfNeeded()
        if !preservedAppend {
            popupDraft = nil
            panel.updateStatus(strings.recordError)
            panel.hide(delay: 2.0)
        }
        if case RecorderError.previousStreamStuck = error {
            restartPending = true
        }
        transition(
            to: .failed(recoverable: !restartPending, message: strings.recordError),
            reason: "recorder_error"
        )
        RuntimeTelemetry.emitRuntimeEvent("session_error", fields: [
            "session_id": id,
            "kind": "recorder_start"
        ])
        completeSession(id: id, reason: "recorder_error", showReady: false)
    }

    // MARK: - Stop

    private func beginStop() {
        guard let id = state.sessionID else { return }
        switch state {
        case .starting, .recording:
            break
        default:
            log("Rejected stop transition from \(String(describing: state)).")
            return
        }
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        transition(to: .stopping(sessionID: id), reason: "hotkey_stop")
        panel.updateStatus(strings.transcribing)
        recorderStartTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.recorder.stop()
            guard self.state.sessionID == id, self.isProcessing else { return }
            self.chunkContinuation?.finish()
            self.chunkContinuation = nil
            if case .stopping = self.state {
                self.transition(to: .processing(sessionID: id, overdue: false), reason: "audio_drained")
            }
            self.log("Recording stopped; draining chunk queue.")
            await self.superviseWorker(sessionId: id)
        }
    }

    /// Wait for the worker, and if it overruns the soft timeout keep the session
    /// blocked (never clear `isProcessing` here) while a watchdog owns the hard
    /// deadline — invariant 6.
    private func superviseWorker(sessionId id: Int) async {
        if await workerFinishes(sessionId: id, within: softTimeout) {
            return
        }
        guard sessionId == id, isProcessing else {
            return
        }

        transition(to: .processing(sessionID: id, overdue: true), reason: "worker_soft_timeout")
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
            guard self.sessionId == id, self.hardAbortedSessionId != id else { return }
            self.hardAbortedSessionId = id

            self.log("Chunk worker exceeded hard timeout (\(Int(hardTimeout))s); aborting the decode.")
            // Release the blocked decode, then drop the model so the next session
            // starts from a clean one. Mirrors the Python child-process restart.
            self.transcriber.abortInFlight()
            RuntimeTelemetry.emitRuntimeEvent("session_error", fields: [
                "session_id": id,
                "kind": "hard_decode_abort"
            ])
            await self.reloadTranscriber(reason: "hard_decode_abort", sessionID: id, force: true)
        }
    }

    private func workerFinishes(sessionId id: Int, within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while workerCompletedSessionId != id {
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
        guard sessionId == id else {
            log("Chunk worker for stale session \(id) exiting.")
            workerCompletedSessionId = id
            return
        }
        // Stop produced no final chunk (too short, or the recorder never started),
        // but partial chunks may still hold the whole phrase.
        if !sawFinalChunk, isProcessing {
            await finalize(sessionId: id)
        }
        workerCompletedSessionId = id
        completeSession(id: id, reason: "worker_finished")
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
            isFinalChunk: chunk.isFinal,
            decodeTimeout: sawFirstDecode
                ? TranscriptionDeadlinePolicy.warmDecodeSeconds
                : TranscriptionDeadlinePolicy.coldDecodeSeconds
        )

        let t0 = ProcessInfo.processInfo.systemUptime
        let result = await transcriber.transcribe(request)
        let t1 = ProcessInfo.processInfo.systemUptime

        let duration = t1 - t0
        let decision = healthMonitor.recordDecode(durationSeconds: duration, coldStart: !sawFirstDecode)
        sawFirstDecode = true

        if decision.shouldRestart {
            restartTranscriberReason = decision.reason
        }

        // The user started a new session while this chunk was decoding; showing
        // its text now would inject stale speech (§6 nr. 11).
        guard sessionId == id else {
            log("Dropping chunk from stale session \(id).")
            return
        }

        switch result.outcome {
        case .success, .noSpeech, .guarded:
            break
        case .timedOut:
            lastTranscriptionError = strings.transcriptionTimeout
        case .aborted:
            lastTranscriptionError = strings.transcriptionError
        case let .failed(failure):
            lastTranscriptionError = failure.message.isEmpty
                ? strings.transcriptionError
                : failure.message
        }

        if !result.text.isEmpty {
            transcribedParts.append(result.text)
            rawChunks.append(result.text)
            if !result.detectedLanguage.isEmpty { detectedLanguage = result.detectedLanguage }
        }

        if chunk.isFinal {
            sawFinalChunk = true
            emitChunkTelemetry(result: result, sessionID: id, isFinal: true, measuredDuration: duration)
            await finalize(sessionId: id)
        } else if !result.text.isEmpty {
            emitChunkTelemetry(result: result, sessionID: id, isFinal: false, measuredDuration: duration)
            panel.updateText(ChunkJoiner.join(transcribedParts))
        } else {
            emitChunkTelemetry(result: result, sessionID: id, isFinal: false, measuredDuration: duration)
        }
    }

    /// Hand the accumulated text to the user for editing.
    private func finalize(sessionId id: Int) async {
        var fullText = ChunkJoiner.join(transcribedParts)
        guard !fullText.isEmpty else {
            if restoreDraftAfterEmptyAppendIfNeeded() {
                log("Nothing recognised while appending to draft in session \(id).")
                return
            }
            let status = lastTranscriptionError ?? strings.noSpeech
            log(lastTranscriptionError == nil
                ? "Nothing recognised in session \(id)."
                : "Transcription failed in session \(id).")
            appendToPopup = false
            popupDraft = nil
            panel.updateStatus(status)
            panel.hide(delay: 2.0)
            return
        }

        if config.aiEditorEnabled, let editor = aiEditor {
            let langs = allowedLanguages()
            let known = VocabProvider.collectKnownTerms(config: .object(config.raw), languages: langs.isEmpty ? nil : langs)
            let mis = VocabProvider.collectEditorHints(
                config: .object(config.raw),
                languages: langs.isEmpty ? nil : langs,
                correctionsURL: dictionaryCoordinator?.correctionsURL
            )

            let editorStartedAt = ProcessInfo.processInfo.systemUptime
            let result = await editor.refine(
                text: fullText,
                languages: langs,
                knownTerms: known,
                misrecognitions: mis
            )
            lastRefineResult = result
            RuntimeTelemetry.emitRuntimeEvent("editor_refine", fields: [
                "session_id": id,
                "duration_ms": (ProcessInfo.processInfo.systemUptime - editorStartedAt) * 1000,
                "status": result.status.rawValue,
                "backend": activeSessionRuntimeDescriptor.aiEditor.backend,
                "model": activeSessionRuntimeDescriptor.aiEditor.modelID ?? "none"
            ])
            if result.status == .ok {
                fullText = result.text
            }
        } else {
            lastRefineResult = nil
        }

        if Self.shouldApplyDirectReplacements(
            after: lastRefineResult?.status,
            hintsInPrompt: activeSessionRuntimeDescriptor.aiEditor.kind == .cloud
        ) {
            let languages = allowedLanguages()
            let pairs = VocabProvider.collectDirectReplacements(
                config: .object(config.raw),
                languages: languages.isEmpty ? nil : languages
            )
            fullText = VocabProvider.applyReplacements(fullText, pairs: pairs)
        }

        let raw = rawChunks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = PopupDraft.Segment(
            sessionID: id,
            rawWhisper: raw,
            aiEdited: lastRefineResult?.status == .ok ? lastRefineResult?.text : nil,
            aiStatus: lastRefineResult?.status.rawValue,
            presentedText: fullText,
            runtime: activeSessionRuntimeDescriptor,
            promptHash: activeSessionPromptHash,
            detectedLanguage: detectedLanguage.isEmpty ? nil : detectedLanguage
        )
        if var draft = popupDraft {
            draft.append(segment)
            popupDraft = draft
        } else {
            var draft = PopupDraft(targetPID: previousAppPid)
            draft.append(segment)
            popupDraft = draft
        }

        if appendToPopup, panel.isShowingInteractive {
            panel.appendText(fullText)
            appendToPopup = false
            panel.setDecisionEnabled(true)
            emitPopupPresentedTelemetry(sessionID: id, appendMode: true)
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
        emitPopupPresentedTelemetry(sessionID: id, appendMode: false)
        log("Interactive popup shown for session \(id) (\(fullText.count) chars).")
    }

    private func completeSession(id: Int, reason: String, showReady: Bool = true) {
        guard completedWorkerSessionId != id else {
            log("Ignoring duplicate worker completion for session \(id).")
            return
        }
        completedWorkerSessionId = id
        overdueWatchdog?.cancel()
        if showReady { panel.updateStatus(strings.ready) }
        completedSessions += 1

        let nextState: SessionState
        if panel.isShowingInteractive {
            nextState = .popup(sessionID: id, targetPID: previousAppPid)
        } else if restartPending {
            nextState = .failed(recoverable: false, message: strings.recordError)
        } else {
            nextState = .idle
        }
        transition(to: nextState, reason: reason)
        RuntimeTelemetry.emitRuntimeEvent("session_worker_complete", fields: [
            "session_id": id,
            "reason": reason
        ])
        var processFields: [String: Any] = [
            "session_id": id,
            "completed_sessions": completedSessions
        ]
        for (key, value) in RuntimeTelemetry.collectProcessMetrics() {
            if let value { processFields[key] = value }
        }
        RuntimeTelemetry.emitRuntimeEvent("process_snapshot", fields: processFields)

        if completedSessions % Self.reloadAfterSessions == 0 {
            pendingPeriodicReload = true
        }
        runDeferredReloadIfIdle()
    }

    // MARK: - Popup callbacks

    private func handleConfirm(_ userText: String) {
        guard claimPopupOutcome(reason: "confirm") else { return }
        let draft = popupDraft
        let raw = draft?.rawWhisper
            ?? rawChunks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = draft?.lastDetectedLanguage
            ?? (detectedLanguage.isEmpty ? config.primaryLanguage : detectedLanguage)
        let pid = draft?.targetPID ?? previousAppPid
        transition(to: .injecting(sessionID: sessionId, targetPID: pid), reason: "popup_confirm")

        let aiEdited: String?
        let aiStatus: String?
        let promptHash: String?
        if let draft {
            aiEdited = draft.aggregateAiEdited
            aiStatus = draft.aggregateAiStatus
            promptHash = draft.aggregatePromptHash
        } else {
            aiEdited = lastRefineResult?.status == .ok ? lastRefineResult?.text : nil
            aiStatus = lastRefineResult?.status.rawValue
            promptHash = activeSessionPromptHash
        }
        let runtime = draft?.aggregateRuntime ?? activeSessionRuntimeDescriptor

        let date = Date()
        let record = DatasetRecord(
            rawWhisper: raw,
            aiEdited: aiEdited,
            aiStatus: aiStatus,
            sttBackend: runtime.transcriber.backend,
            sttModel: runtime.transcriber.modelID,
            aiModel: runtime.aiEditor.modelID,
            userFinal: userText,
            lang: lang,
            promptHash: promptHash,
            userTerms: UserTerms.activeTerms(config, lang: lang),
            segments: draft?.datasetSegments
        )

        if let dictionaryCoordinator {
            let confirmation = DictionaryConfirmation(
                sessionID: sessionId,
                datasetRecord: record,
                finalText: userText,
                date: date
            )
            Task { @MainActor [weak self] in
                let persisted = await dictionaryCoordinator.recordConfirmation(confirmation)
                guard let self else { return }
                self.config = dictionaryCoordinator.snapshot
                if persisted.historySaved { self.onPhraseHistoryChanged() }
            }
        } else {
            let datasetLogger = datasetLogger
            let phraseHistory = phraseHistory
            Task { @MainActor [weak self] in
                let historySaved = await Task.detached(priority: .utility) {
                    datasetLogger?.append(record, at: date)
                    return phraseHistory?.append(userText, at: date) == true
                }.value
                if historySaved { self?.onPhraseHistoryChanged() }
            }
        }

        guard !userText.isEmpty else {
            popupDraft = nil
            log("Confirmed with empty text; nothing to inject.")
            transition(to: .idle, reason: "empty_confirm")
            runDeferredReloadIfIdle()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // Let the popup's close finish on the run loop before another app is
            // activated, exactly as the Python 0.2 s pause does.
            try? await Task.sleep(nanoseconds: 200_000_000)
            let delivered = await self.delivery.deliver(userText + Self.injectionSuffix, to: pid)
            self.log("Injection finished: delivered=\(delivered) chars=\(userText.count)")
            if case let .injecting(activeID, _) = self.state, activeID == self.sessionId {
                if delivered { self.popupDraft = nil }
                self.transition(to: .idle, reason: delivered ? "injection_complete" : "injection_failed")
                self.runDeferredReloadIfIdle()
            }
        }
    }

    private func handleCancel() {
        guard claimPopupOutcome(reason: "cancel") else { return }
        popupDraft = nil
        log("User cancelled from popup.")
        transition(to: .idle, reason: "popup_cancel")
        runDeferredReloadIfIdle()
    }

    private func claimPopupOutcome(reason: String) -> Bool {
        guard case let .popup(activeID, _) = state, activeID == sessionId else {
            log("Ignoring popup outcome outside popup state for session \(sessionId).")
            return false
        }
        guard completedOutcomeSessionId != sessionId else {
            log("Ignoring duplicate popup outcome for session \(sessionId).")
            return false
        }
        completedOutcomeSessionId = sessionId
        RuntimeTelemetry.emitRuntimeEvent(
            "session_end",
            fields: ["session_id": sessionId, "reason": reason]
        )
        return true
    }

    @discardableResult
    private func restoreDraftAfterEmptyAppendIfNeeded() -> Bool {
        guard appendToPopup, popupDraft != nil, panel.isShowingInteractive else { return false }
        appendToPopup = false
        panel.setDecisionEnabled(true)
        return true
    }

    /// ⌘D in the popup: route the term to the language matching its script, then
    /// rebuild the prompt and let the owner persist the config.
    private func handleAddToDictionary(_ term: String) -> AddTermResult {
        let lang = UserTerms.targetLanguage(for: term, config: config)
        if let dictionaryCoordinator {
            guard dictionaryCoordinator.addManualTerm(term, language: lang) else {
                return .alreadyExists
            }
            config = dictionaryCoordinator.snapshot
            log("Added term to dictionary via coordinator: \(term) -> \(lang)")
            let langName = LanguageCode.displayNames[lang] ?? lang.uppercased()
            return .added(message: "„\(term)“ → \(langName)")
        }
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

    /// Startup and lifecycle keepalive entry point. Synthetic work is accepted
    /// only in true idle; the hotkey path never calls this method.
    @discardableResult
    public func warmupIfIdle(full: Bool, language: String? = nil) async -> Bool {
        guard isRuntimeIdle, runtimeAvailable, !restartPending else { return false }
        let transcriber = self.transcriber
        let startedAt = ProcessInfo.processInfo.systemUptime
        let task = Task {
            if full {
                await transcriber.warmup(language: language)
            } else {
                await transcriber.preWarm()
            }
        }
        warmupTask = task
        await task.value
        warmupTask = nil
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        let decision = healthMonitor.recordPrewarm(durationSeconds: duration, success: true)
        RuntimeTelemetry.emitRuntimeEvent("transcriber_prewarm", fields: [
            "full": full,
            "duration_ms": duration * 1000,
            "accepted_while_idle": true
        ])
        if decision.shouldRestart {
            restartTranscriberReason = decision.reason
            runDeferredReloadIfIdle()
        }
        return true
    }

    private func transition(to newState: SessionState, reason: String) {
        let oldState = state
        state = newState
        onStateChanged(newState)
        log("Session state \(String(describing: oldState)) -> \(String(describing: newState)) (\(reason)).")
    }

    private func emitChunkTelemetry(
        result: TranscriptionResult,
        sessionID: Int,
        isFinal: Bool,
        measuredDuration: TimeInterval
    ) {
        RuntimeTelemetry.emitRuntimeEvent("chunk_processed", fields: [
            "session_id": sessionID,
            "is_final": isFinal,
            "duration_ms": (result.durationSeconds > 0 ? result.durationSeconds : measuredDuration) * 1000,
            "outcome": result.outcome.telemetryValue,
            "stt_backend": result.backend ?? activeSessionRuntimeDescriptor.transcriber.backend,
            "stt_model": result.modelID ?? activeSessionRuntimeDescriptor.transcriber.modelID,
            "retry_count": result.retryCount
        ])
    }

    private func emitPopupPresentedTelemetry(sessionID: Int, appendMode: Bool) {
        var fields: [String: Any] = [
            "session_id": sessionID,
            "append_mode": appendMode
        ]
        if let stopRequestedUptime {
            fields["stop_to_popup_ms"] = max(
                0,
                (ProcessInfo.processInfo.systemUptime - stopRequestedUptime) * 1000
            )
        }
        RuntimeTelemetry.emitRuntimeEvent("popup_presented", fields: fields)
    }

    private func runDeferredReloadIfIdle() {
        guard isRuntimeIdle else { return }
        let reason: String
        if let healthReason = restartTranscriberReason {
            reason = healthReason
            restartTranscriberReason = nil
        } else if pendingPeriodicReload {
            reason = "periodic_\(completedSessions)_sessions"
            pendingPeriodicReload = false
        } else {
            return
        }
        let id = sessionId
        Task { [weak self] in
            await self?.reloadTranscriber(reason: reason, sessionID: id, force: false)
        }
    }

    private func reloadTranscriber(reason: String, sessionID id: Int, force: Bool) async {
        guard !reloadInProgress else { return }
        guard force || isRuntimeIdle else {
            restartTranscriberReason = reason
            return
        }
        reloadInProgress = true
        onBeforeTranscriberReload()
        log("Reloading transcriber (reason: \(reason), session: \(id)).")
        await transcriber.reload()
        healthMonitor.markRestarted()
        reloadInProgress = false
        runDeferredReloadIfIdle()
    }

    /// `hashlib.md5(initial_prompt)[:12]` — a fingerprint of the prompt in effect,
    /// used to correlate dataset rows with dictionary changes.
    static func promptHash(_ prompt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(prompt.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    public func transcribeFile(
        url: URL,
        refine: Bool = false,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void = { _ in }
    ) async -> FileTranscriptionResult {
        guard isRuntimeIdle, runtimeAvailable, !restartPending else {
            return .failed(.init(kind: .unavailable, message: "Another transcription is already running"))
        }
        fileJobActive = true
        transition(to: .fileProcessing, reason: "file_transcription_start")
        defer {
            fileJobActive = false
            if state == .fileProcessing {
                transition(to: .idle, reason: "file_transcription_finished")
                runDeferredReloadIfIdle()
            }
        }
        let fileRuntime = runtimeDescriptorProvider()

        let request = FileTranscriptionRequest(
            url: url,
            initialPrompt: config.initialPrompt.isEmpty ? nil : config.initialPrompt,
            allowedLanguages: allowedLanguages(),
            refine: refine
        )
        var result = await transcriber.transcribeFile(request, progress: progress)
        guard case .success = result.status else { return result }

        let languages = allowedLanguages()
        var refineStatus: RefineStatus?
        if refine, let aiEditor {
            progress(.init(stage: .refining, completedUnits: 0, totalUnits: 1))
            let known = VocabProvider.collectKnownTerms(
                config: .object(config.raw),
                languages: languages.isEmpty ? nil : languages
            )
            let misrecognitions = VocabProvider.collectEditorHints(
                config: .object(config.raw),
                languages: languages.isEmpty ? nil : languages,
                correctionsURL: dictionaryCoordinator?.correctionsURL
            )
            let refined = await aiEditor.refineFileText(
                text: result.text,
                languages: languages,
                knownTerms: known,
                misrecognitions: misrecognitions
            )
            refineStatus = refined.status
            if refined.status == .ok { result.text = refined.text }
        }

        if Self.shouldApplyDirectReplacements(
            after: refineStatus,
            hintsInPrompt: fileRuntime.aiEditor.kind == .cloud
        ) {
            let pairs = VocabProvider.collectDirectReplacements(
                config: .object(config.raw),
                languages: languages.isEmpty ? nil : languages
            )
            result.text = VocabProvider.applyReplacements(result.text, pairs: pairs)
        }
        progress(.init(stage: .completed, completedUnits: 1, totalUnits: 1))
        return result
    }

    static func shouldApplyDirectReplacements(
        after status: RefineStatus?,
        hintsInPrompt: Bool
    ) -> Bool {
        guard let status else { return true }
        switch status {
        case .disabled, .skipped, .timeout, .error, .memoryPressure:
            return true
        case .ok:
            return false
        case .unchanged:
            return !hintsInPrompt
        }
    }

    public func cancelFileTranscription() {
        guard fileJobActive else { return }
        transcriber.abortInFlight()
    }
}

/// One audio chunk on its way from the recorder to the transcriber.
struct SessionChunk: Sendable {
    let audio: [Float]
    let isFinal: Bool
    let sessionId: Int
}
