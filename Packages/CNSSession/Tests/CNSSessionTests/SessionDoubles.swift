import CNSCore
import CNSDictionary
import CNSTranscription

import Foundation
@testable import CNSSession

/// Records what the popup was told to do, and lets a test act as the user.
@MainActor
final class FakePanel: PopupPresenting {
    enum Event: Equatable {
        case show(String)
        case status(String)
        case text(String)
        case interactive(String)
        case append(String)
        case incompleteWarning(String)
        case decisionEnabled(Bool)
        case hide
    }

    private(set) var events: [Event] = []
    private(set) var isShowingInteractive = false
    private(set) var shownText = ""
    private(set) var decisionEnabled = true

    private var onConfirm: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var onAddToDictionary: ((String) -> AddTermResult)?

    func show(title: String) { events.append(.show(title)) }
    func updateStatus(_ title: String) { events.append(.status(title)) }
    func updateText(_ text: String) { events.append(.text(text)) }

    func appendText(_ text: String) {
        shownText += " " + text
        events.append(.append(text))
    }

    func setDecisionEnabled(_ enabled: Bool) {
        decisionEnabled = enabled
        events.append(.decisionEnabled(enabled))
    }

    func showIncompleteWarning(_ message: String) {
        events.append(.incompleteWarning(message))
    }

    func hide(delay: TimeInterval) {
        events.append(.hide)
        isShowingInteractive = false
    }

    func showInteractive(
        text: String,
        title: String,
        toasts: DictionaryToasts,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onAddToDictionary: ((String) -> AddTermResult)?
    ) {
        shownText = text
        isShowingInteractive = true
        decisionEnabled = true
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onAddToDictionary = onAddToDictionary
        events.append(.interactive(text))
    }

    // MARK: - Acting as the user

    func userConfirms(_ text: String? = nil) {
        guard decisionEnabled else { return }
        let value = text ?? shownText
        isShowingInteractive = false
        onConfirm?(value)
    }

    func userCancels() {
        guard decisionEnabled else { return }
        isShowingInteractive = false
        onCancel?()
    }

    func userEdits(_ text: String) {
        shownText = text
    }

    func userAddsTerm(_ term: String) -> AddTermResult? {
        onAddToDictionary?(term)
    }

    var statuses: [String] {
        events.compactMap { if case let .status(s) = $0 { return s } else { return nil } }
    }

    var interactiveTexts: [String] {
        events.compactMap { if case let .interactive(s) = $0 { return s } else { return nil } }
    }

    var incompleteWarnings: [String] {
        events.compactMap {
            if case let .incompleteWarning(message) = $0 { return message }
            return nil
        }
    }
}

/// A recorder that emits exactly the chunks a test scripts, with no audio stack.
final class FakeRecorder: AudioCapturing, @unchecked Sendable {
    // @unchecked Sendable: touched only from the test's main actor and from the
    // controller's start task, never concurrently.
    private let lock = NSLock()
    private var callbacks: AudioCallbacks?
    private var recording = false
    /// Chunks handed to the pipeline on `stop()`; the last one is the final chunk.
    var scriptedChunks: [[Float]] = []
    var finalChunk: [Float]?
    var startError: Error?
    var suspendStart = false
    var ignoreStartCancellation = false
    var duplicateFinalCallback = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recording
    }

    func start(callbacks: AudioCallbacks) async throws {
        if let startError { throw startError }
        let shouldSuspend = lock.withLock { () -> Bool in
            startCount += 1
            return suspendStart
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                lock.lock()
                startContinuation = continuation
                lock.unlock()
            }
        }
        if !ignoreStartCancellation { try Task.checkCancellation() }
        store(callbacks)
    }

    func resumeStart() {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    /// NSLock is unavailable directly in an async context, so the mutation lives
    /// in a synchronous helper.
    private func store(_ callbacks: AudioCallbacks) {
        lock.lock()
        staleCallbacks = self.callbacks
        self.callbacks = callbacks
        recording = true
        lock.unlock()
    }

    /// Callbacks handed out for the previous session, kept so a test can pretend
    /// an old audio thread fired late.
    private var staleCallbacks: AudioCallbacks?

    func emitStaleChunk(_ samples: [Float]) {
        lock.lock(); let cb = staleCallbacks; lock.unlock()
        cb?.onChunk(samples)
    }

    func stop() async {
        let cb = lock.withLock { () -> AudioCallbacks? in
            recording = false
            stopCount += 1
            return callbacks
        }
        guard let cb else { return }
        for chunk in scriptedChunks { cb.onChunk(chunk) }
        cb.onFinal(finalChunk)
        if duplicateFinalCallback { cb.onFinal(finalChunk) }
    }

    /// Emit a non-final chunk mid-recording.
    func emitChunk(_ samples: [Float]) {
        lock.lock(); let cb = callbacks; lock.unlock()
        cb?.onChunk(samples)
    }

    func emitConfigurationChange() {
        lock.lock(); let cb = callbacks; lock.unlock()
        cb?.onCaptureInterrupted(.configurationChanged)
    }
}

/// Returns scripted texts, one per chunk, and can be made slow on demand.
actor FakeTranscriber: Transcribing {
    private var texts: [String]
    private var scriptedResults: [TranscriptionResult]
    private let delay: TimeInterval
    private(set) var requests: [TranscriptionRequest] = []
    private(set) var reloadCount = 0
    private(set) var warmupCount = 0
    private(set) var preWarmCount = 0
    private let aborted = AbortBox()
    private let aborts = LockedCounter()
    private var suspendNextDecode = false
    private var decodeContinuation: CheckedContinuation<Void, Never>?
    private var suspendReload = false
    private var reloadContinuation: CheckedContinuation<Void, Never>?
    private var suspendPreWarm = false
    private(set) var preWarmCancelledCount = 0

    init(
        texts: [String],
        results: [TranscriptionResult] = [],
        delay: TimeInterval = 0
    ) {
        self.texts = texts
        self.scriptedResults = results
        self.delay = delay
    }

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        requests.append(request)
        // The real engine clears its abort flag when a decode starts, not when
        // the model reloads — a reload can land between two decode steps.
        aborted.value = false
        if suspendNextDecode {
            suspendNextDecode = false
            await withCheckedContinuation { decodeContinuation = $0 }
        }
        if delay > 0 {
            // Stop early when the watchdog aborts, the way whisper.cpp's abort
            // callback ends a real decode.
            let step = 0.02
            var waited = 0.0
            while waited < delay, !aborted.value {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                waited += step
            }
            if aborted.value {
                return .empty
            }
        }
        if !scriptedResults.isEmpty {
            return scriptedResults.removeFirst()
        }
        guard !texts.isEmpty else { return .empty }
        let text = texts.removeFirst()
        return TranscriptionResult(text: text, detectedLanguage: "ru")
    }

    func suspendOneDecode() {
        suspendNextDecode = true
    }

    func waitUntilRequestCount(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }

    func resumeDecode() {
        decodeContinuation?.resume()
        decodeContinuation = nil
    }

    func reload() async {
        reloadCount += 1
        if suspendReload {
            await withCheckedContinuation { reloadContinuation = $0 }
        }
    }

    func setSuspendReload(_ suspended: Bool) {
        suspendReload = suspended
    }

    func waitUntilReloadStarted() async {
        while reloadCount == 0 { await Task.yield() }
    }

    func finishReload() {
        reloadContinuation?.resume()
        reloadContinuation = nil
    }

    func warmup(language: String?) async {
        warmupCount += 1
    }

    func preWarm() async -> PrewarmResult {
        preWarmCount += 1
        while suspendPreWarm {
            if Task.isCancelled {
                preWarmCancelledCount += 1
                return .skipped
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return .warmed
    }

    func setSuspendPreWarm(_ suspended: Bool) {
        suspendPreWarm = suspended
    }

    func waitUntilPreWarmStarted() async {
        while preWarmCount == 0 { await Task.yield() }
    }

    nonisolated func abortInFlight() {
        aborted.value = true
        aborts.increment()
    }

    var requestCount: Int { requests.count }
    var abortCount: Int { aborts.value }
}

/// Holds a file transcription open so activity-exclusion tests can exercise
/// the real SessionController guard while the request is in flight.
actor SuspendingFileTranscriber: Transcribing {
    private(set) var fileRequestCount = 0
    private(set) var fileRequests: [FileTranscriptionRequest] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var progressCallbacks: [@Sendable (FileTranscriptionProgress) -> Void] = []

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        .empty
    }

    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        fileRequestCount += 1
        fileRequests.append(request)
        progressCallbacks.append(progress)
        await withCheckedContinuation { continuations.append($0) }
        return FileTranscriptionResult(text: "file text", status: .success)
    }

    func waitUntilStarted() async {
        while fileRequestCount == 0 { await Task.yield() }
    }

    func finish() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func emitProgress(_ update: FileTranscriptionProgress, call index: Int) {
        progressCallbacks[index](update)
    }
}

actor SuspendingFileAiEditor: AiEditing {
    nonisolated let isReady = true
    private(set) var cancellationCount = 0
    private var started = false

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
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
            return RefineResult(text: "late refined text", status: .ok)
        } catch is CancellationError {
            cancellationCount += 1
            return RefineResult(text: text, status: .skipped)
        } catch {
            return RefineResult(text: text, status: .error)
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

actor FileProgressRecorder {
    private(set) var updates: [FileTranscriptionProgress] = []

    func append(_ update: FileTranscriptionProgress) {
        updates.append(update)
    }

    func waitForCount(_ count: Int) async {
        while updates.count < count { await Task.yield() }
    }
}

/// Shared abort flag for `FakeTranscriber` (its abort must be callable from
/// outside the actor, exactly like the real one).
final class AbortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@MainActor
final class FakeDelivery: TextDelivering {
    private(set) var delivered: [(text: String, pid: pid_t?)] = []
    var outcome: TextDeliveryOutcome = .delivered
    var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    func deliver(_ text: String, to pid: pid_t?) async -> TextDeliveryOutcome {
        delivered.append((text, pid))
        if suspend {
            await withCheckedContinuation { continuation = $0 }
        }
        return outcome
    }

    func resume() {
        suspend = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FakeFrontmost: FrontmostAppProviding {
    var pid: pid_t? = 4242
    func frontmostPid() -> pid_t? { pid }
}

@MainActor
final class FakeDictionaryCoordinator: DictionaryCoordinating {
    private(set) var snapshot: Config
    let correctionsURL: URL
    private(set) var confirmations: [DictionaryConfirmation] = []
    private(set) var addedTerms: [(term: String, language: String)] = []
    var suspendConfirmation = false
    private(set) var confirmationStarted = false
    private var confirmationContinuation: CheckedContinuation<Void, Never>?

    init(config: Config) {
        snapshot = config
        correctionsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-corrections-\(UUID().uuidString).json")
    }

    func recordConfirmation(_ confirmation: DictionaryConfirmation) async -> ConfirmationPersistenceResult {
        confirmationStarted = true
        if suspendConfirmation {
            await withCheckedContinuation { confirmationContinuation = $0 }
        }
        confirmations.append(confirmation)
        return ConfirmationPersistenceResult(datasetSaved: true, correctionsUpdated: true, historySaved: true)
    }

    func finishConfirmation() {
        suspendConfirmation = false
        confirmationContinuation?.resume()
        confirmationContinuation = nil
    }

    func addManualTermValidated(_ term: String, language: String) throws -> Bool {
        return true
    }

    func addManualTerm(_ term: String, language: String) -> Bool {
        return true
    }
}

final class ShutdownResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: SessionShutdownOutcome?

    func record(_ outcome: SessionShutdownOutcome) {
        lock.withLock { storage = outcome }
    }

    var value: SessionShutdownOutcome? {
        lock.withLock { storage }
    }
}

/// A fake AI editor for testing integration.
final class FakeAiEditor: AiEditing, @unchecked Sendable {
    var isReady: Bool = true
    var refineDelay: TimeInterval = 0
    var refinedText: String = "refined text"
    var refineStatus: RefineStatus = .ok
    var lastInputText: String?
    var lastMisrecognitions: [(String, String)]?
    var lastLanguages: [String]?
    var didCallRefine = false

    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        didCallRefine = true
        lastInputText = text
        lastMisrecognitions = misrecognitions
        lastLanguages = languages
        if refineDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(refineDelay * 1_000_000_000))
        }
        return RefineResult(text: refinedText, status: refineStatus)
    }

    func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        lastMisrecognitions = misrecognitions
        lastLanguages = languages
        return RefineResult(text: refinedText, status: refineStatus)
    }
}
