import CNSAudio
import CNSTranscription
import CNSUI
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
        case hide
    }

    private(set) var events: [Event] = []
    private(set) var isShowingInteractive = false
    private(set) var shownText = ""

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
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onAddToDictionary = onAddToDictionary
        events.append(.interactive(text))
    }

    // MARK: - Acting as the user

    func userConfirms(_ text: String? = nil) {
        let value = text ?? shownText
        isShowingInteractive = false
        onConfirm?(value)
    }

    func userCancels() {
        isShowingInteractive = false
        onCancel?()
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
}

/// A recorder that emits exactly the chunks a test scripts, with no audio stack.
final class FakeRecorder: AudioCapturing, @unchecked Sendable {
    // @unchecked Sendable: touched only from the test's main actor and from the
    // controller's start task, never concurrently.
    private let lock = NSLock()
    private var callbacks: AudioRecorder.Callbacks?
    private var recording = false
    /// Chunks handed to the pipeline on `stop()`; the last one is the final chunk.
    var scriptedChunks: [[Float]] = []
    var finalChunk: [Float]?
    var startError: Error?

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recording
    }

    func start(callbacks: AudioRecorder.Callbacks) async throws {
        if let startError { throw startError }
        store(callbacks)
    }

    /// NSLock is unavailable directly in an async context, so the mutation lives
    /// in a synchronous helper.
    private func store(_ callbacks: AudioRecorder.Callbacks) {
        lock.lock()
        staleCallbacks = self.callbacks
        self.callbacks = callbacks
        recording = true
        lock.unlock()
    }

    /// Callbacks handed out for the previous session, kept so a test can pretend
    /// an old audio thread fired late.
    private var staleCallbacks: AudioRecorder.Callbacks?

    func emitStaleChunk(_ samples: [Float]) {
        lock.lock(); let cb = staleCallbacks; lock.unlock()
        cb?.onChunk(samples)
    }

    func stop() {
        lock.lock()
        let cb = callbacks
        recording = false
        lock.unlock()
        guard let cb else { return }
        for chunk in scriptedChunks { cb.onChunk(chunk) }
        cb.onFinal(finalChunk)
    }

    /// Emit a non-final chunk mid-recording.
    func emitChunk(_ samples: [Float]) {
        lock.lock(); let cb = callbacks; lock.unlock()
        cb?.onChunk(samples)
    }
}

/// Returns scripted texts, one per chunk, and can be made slow on demand.
actor FakeTranscriber: Transcribing {
    private var texts: [String]
    private let delay: TimeInterval
    private(set) var requests: [TranscriptionRequest] = []
    private(set) var reloadCount = 0
    private(set) var abortCount = 0
    private let aborted = AbortBox()

    init(texts: [String], delay: TimeInterval = 0) {
        self.texts = texts
        self.delay = delay
    }

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        requests.append(request)
        // The real engine clears its abort flag when a decode starts, not when
        // the model reloads — a reload can land between two decode steps.
        aborted.value = false
        if delay > 0 {
            // Stop early when the watchdog aborts, the way whisper.cpp's abort
            // callback ends a real decode.
            let step = 0.02
            var waited = 0.0
            while waited < delay, !aborted.value {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                waited += step
            }
            if aborted.value { return .empty }
        }
        guard !texts.isEmpty else { return .empty }
        return TranscriptionResult(text: texts.removeFirst(), detectedLanguage: "ru")
    }

    func reload() async {
        reloadCount += 1
    }

    nonisolated func abortInFlight() {
        aborted.value = true
    }

    var requestCount: Int { requests.count }
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

@MainActor
final class FakeDelivery: TextDelivering {
    private(set) var delivered: [(text: String, pid: pid_t?)] = []
    var succeeds = true

    func deliver(_ text: String, to pid: pid_t?) async -> Bool {
        delivered.append((text, pid))
        return succeeds
    }
}

@MainActor
final class FakeFrontmost: FrontmostAppProviding {
    var pid: pid_t? = 4242
    func frontmostPid() -> pid_t? { pid }
}

/// A fake AI editor for testing integration.
final class FakeAiEditor: AiEditing, @unchecked Sendable {
    var isReady: Bool = true
    var refineDelay: TimeInterval = 0
    var refinedText: String = "refined text"
    var lastInputText: String?
    var didCallRefine = false
    
    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        didCallRefine = true
        lastInputText = text
        if refineDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(refineDelay * 1_000_000_000))
        }
        return RefineResult(text: refinedText, status: .ok)
    }
    
    func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        return RefineResult(text: text, status: .ok)
    }
}
