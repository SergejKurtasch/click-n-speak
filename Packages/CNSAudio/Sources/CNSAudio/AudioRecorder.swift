@preconcurrency import AVFoundation
import Foundation
import os
import CNSCore

/// Captures microphone audio via AVAudioEngine and emits speech chunks.
///
/// Ported from `recorder.py` with the §4.5 restructure: the tap does nothing but
/// convert to 16 kHz mono and write into a `SampleRingBuffer`; a consumer task
/// runs the VAD and `AudioChunker` off the audio thread. Chunk thresholds and
/// the final-chunk guard are preserved 1:1.

/// Translates the Python `sounddevice` stream loop into a Swift `AVAudioEngine`
/// tap. Resamples whatever format the default microphone provides to 16kHz mono.
public enum AudioRecorderError: LocalizedError, Sendable, Equatable {
    case invalidInputFormat(sampleRate: Double, channels: Int)
    case converterUnavailable
    case engineStartFailed(String)
    case tapInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInputFormat(rate, channels):
            "The microphone reported an invalid format (\(rate) Hz, \(channels) channels)"
        case .converterUnavailable:
            "The microphone format could not be converted"
        case let .engineStartFailed(message):
            "The audio engine could not start: \(message)"
        case let .tapInstallFailed(message):
            "The audio capture tap could not be installed: \(message)"
        }
    }

    var isTapInstallFailure: Bool {
        if case .tapInstallFailed = self { return true }
        return false
    }
}

public enum EngineResetReason: Sendable, Equatable {
    case none
    case tapInstallFailure
    case engineStartFailure
}

public final class AudioRecorder: AudioCapturing, @unchecked Sendable {
    public typealias Callbacks = AudioCallbacks

    private let config: ChunkingConfig
    private let vad: VoiceActivityDetecting
    private let log: @Sendable (String) -> Void
    private let playsSounds: Bool
    private let closeWatchdog: StreamCloseWatchdog
    private let engineAdapter: any AudioEngineAdapting

    /// Serializes graph start/stop. The tap has a separate short-lived gate so
    /// stop can wait for a callback that already owns a buffer before draining.
    private let engineLock = NSLock()
    private let tapWorkLock = NSLock()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let ringBuffer: SampleRingBuffer

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var recording = false
        var stopping = false
        var acceptingSamples = false
        var tapInstalled = false
        var graphSetupInProgress = false
        var teardownStarted = false
        var interruptionReported = false
        var generation = 0
        var callbacks = Callbacks()
        var chunker = AudioChunker()
        var accumulation: [Float] = []   // samples for the current (non-emitted) chunk
        var pendingFrame: [Float] = []    // leftover < one VAD frame
        var overflowSamples = 0
        var maximumTapDurationMs = 0.0
        var engineResetReason: EngineResetReason = .none
        var lastEngineResetUptime: TimeInterval = 0
        var configurationRestarts = 0
        var setupInvalidated = false
        var formatMismatchCount = 0
    }
    private var consumerTask: Task<Void, Never>?

    /// Route switches (e.g. a Bluetooth headset entering HFP when its mic opens)
    /// post `AVAudioEngineConfigurationChange` right after start. Capture is
    /// restarted in place up to this many times per session before giving up.
    static let maxConfigurationRestarts = 3

    /// The notification may be posted synchronously from inside engine calls
    /// that already hold `engineLock`, so restarts hop to this serial queue.
    private let configurationQueue = DispatchQueue(
        label: "com.sergej.clicknspeak.audio-configuration",
        qos: .userInitiated
    )

    private enum ConfigurationChangeAction {
        case ignore
        case interrupt(Callbacks)
        case restart(generation: Int)
    }

    private let frameSamples: Int  // VAD frame size (30 ms)

    public static func validateInputFormat(sampleRate: Double, channels: Int) throws {
        guard sampleRate > 0, channels > 0 else {
            throw AudioRecorderError.invalidInputFormat(sampleRate: sampleRate, channels: channels)
        }
    }

    /// - Parameters:
    ///   - vad: defaults to libfvad (webrtcvad parity with the Python app, which
    ///     the chunking thresholds are calibrated against).
    ///   - playsSounds: start/stop cues, as in `recorder.py`. Off in tests.
    ///   - onFatalError: the audio stream failed to tear down within
    ///     `streamCloseTimeout`; the app must restart itself (see
    ///     `_on_recorder_fatal_error` in `app.py`).
    public init(
        config: ChunkingConfig = ChunkingConfig(),
        vad: VoiceActivityDetecting = FVADVoiceActivityDetector(),
        engineAdapter: (any AudioEngineAdapting)? = nil,
        playsSounds: Bool = true,
        streamCloseTimeout: TimeInterval = 12.0,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onFatalError: @escaping @Sendable () -> Void = {}
    ) {
        self.config = config
        self.vad = vad
        self.engineAdapter = engineAdapter ?? AVAudioEngineAdapter()
        self.log = log
        self.playsSounds = playsSounds
        self.closeWatchdog = StreamCloseWatchdog(
            timeout: streamCloseTimeout,
            log: log,
            onHang: onFatalError
        )
        self.frameSamples = Int(Double(config.sampleRate) * 0.03)
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(config.sampleRate),
            channels: 1,
            interleaved: false
        )!
        self.ringBuffer = SampleRingBuffer(capacitySeconds: 30, sampleRate: config.sampleRate)
        self.engineAdapter.setConfigurationChangeHandler { [weak self] in
            self?.handleConfigurationChange()
        }
    }

    public var isRecording: Bool {
        stateLock.withLock { $0.recording }
    }

    // MARK: - Start / stop

    /// Async because of the start cue: the beep plays *before* the input opens and
    /// we wait it out so it is not recorded (`play_sound` + `time.sleep(0.2)` in
    /// `recorder.start`). Suspending keeps that wait off the caller's thread.
    public func start(callbacks: Callbacks) async throws {
        try await start(callbacks: callbacks, settings: RecordingSettings(
            silenceDurationLimit: config.silenceDuration,
            targetChunkDuration: config.targetSpeechDuration,
            minChunkDuration: config.minSpeechDuration,
            maxChunkDuration: config.maxSpeechDuration
        ))
    }

    public func start(callbacks: Callbacks, settings: RecordingSettings) async throws {
        let chunkingConfig = ChunkingConfig(settings: settings, sampleRate: config.sampleRate)
        let generation: Int? = stateLock.withLock { state in
            if state.recording || state.stopping { return nil }
            state.generation += 1
            state.recording = true
            state.stopping = false
            state.acceptingSamples = false
            state.tapInstalled = false
            state.graphSetupInProgress = false
            state.teardownStarted = false
            state.interruptionReported = false
            state.configurationRestarts = 0
            state.callbacks = callbacks
            state.chunker = AudioChunker(config: chunkingConfig)
            state.accumulation.removeAll(keepingCapacity: true)
            state.pendingFrame.removeAll(keepingCapacity: true)
            state.overflowSamples = 0
            state.maximumTapDurationMs = 0
            return state.generation
        }
        guard let generation else { return }
        ringBuffer.clear()

        // A stream still tearing down holds Core Audio state; opening a new one on
        // top of it either deadlocks or yields a stream that captures nothing.
        guard await closeWatchdog.awaitPendingClose() else {
            resetFailedStart(generation: generation)
            throw RecorderError.previousStreamStuck
        }
        try ensureStartIsActive(generation: generation)

        if playsSounds {
            RecordingSounds.playStart()
            try await Task.sleep(nanoseconds: UInt64(RecordingSounds.startSoundLeadTime * 1_000_000_000))
        }
        try ensureStartIsActive(generation: generation)

        resetEngineIfNeeded()

        let inputSampleRate: Double
        do {
            inputSampleRate = try performEngineStart(generation: generation)
        } catch {
            scheduleGraphTeardownIfNeeded(generation: generation)
            let reason: EngineResetReason
            if case .engineStartFailed = error as? AudioRecorderError {
                reason = .engineStartFailure
            } else if case .tapInstallFailed = error as? AudioRecorderError {
                reason = .tapInstallFailure
            } else {
                reason = .none
            }
            resetFailedStart(generation: generation, reason: reason)
            throw error
        }
        let startStillActive = stateLock.withLock { state -> Bool in
            guard state.generation == generation,
                  state.recording,
                  !state.stopping,
                  !state.interruptionReported else { return false }
            state.acceptingSamples = true
            return true
        }
        guard startStillActive else {
            await stop()
            throw CancellationError()
        }
        startConsumer()
        log("AudioRecorder started (input \(Int(inputSampleRate)) Hz → \(config.sampleRate) Hz)")
    }

    /// Stop recording. Drains the buffer, applies the final-chunk guard, and
    /// delivers the final chunk via `onFinal`.
    public func stop() async {
        let stopContext: (Callbacks, Int)? = stateLock.withLock { state in
            guard state.recording, !state.stopping else { return nil }
            state.stopping = true
            state.acceptingSamples = false
            return (state.callbacks, state.generation)
        }
        guard let (callbacks, generation) = stopContext else { return }

        scheduleGraphTeardownIfNeeded(generation: generation)

        let consumer = consumerTask
        consumer?.cancel()
        await consumer?.value
        consumerTask = nil

        if playsSounds { RecordingSounds.playStop() }

        // The consumer is now joined, so this task is the sole ring-buffer
        // reader. Process every complete VAD frame before assembling the tail.
        while drainAndProcess() {}
        emitPendingAudioTelemetry(generation: generation)
        let finalChunk: [Float] = stateLock.withLock { state in
            state.accumulation.append(contentsOf: state.pendingFrame)
            let assembled = state.accumulation
            state.accumulation.removeAll(keepingCapacity: true)
            state.pendingFrame.removeAll(keepingCapacity: true)
            return assembled
        }

        if finalChunk.count >= Int(Double(config.sampleRate) * 0.3) {
            callbacks.onFinal(finalChunk)
        } else {
            log("Final chunk too short (\(finalChunk.count) samples) — discarded.")
            callbacks.onFinal(nil)
        }

        stateLock.withLock { state in
            guard state.generation == generation else { return }
            state.recording = false
            state.stopping = false
            state.acceptingSamples = false
            state.tapInstalled = false
            state.graphSetupInProgress = false
            state.interruptionReported = false
            state.callbacks = Callbacks()
        }
        converter = nil
    }

    // MARK: - Tap (audio thread): convert + write only

    private func handleTap(_ buffer: AVAudioPCMBuffer, generation: Int) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard stateLock.withLock({
            $0.generation == generation && $0.acceptingSamples
        }) else { return }
        tapWorkLock.lock()
        defer { tapWorkLock.unlock() }
        guard stateLock.withLock({
            $0.generation == generation && $0.acceptingSamples
        }) else { return }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let feeder = SingleBufferFeeder(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            feeder.next(inputStatus)
        }
        guard status != .error, let channel = out.floatChannelData?[0] else {
            handleTapFormatMismatch(buffer: buffer, converter: converter, generation: generation)
            return
        }
        stateLock.withLock { state in
            if state.generation == generation { state.formatMismatchCount = 0 }
        }
        let count = Int(out.frameLength)
        if count > 0 {
            let dropped = ringBuffer.write(Array(UnsafeBufferPointer(start: channel, count: count)))
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            stateLock.withLock { state in
                state.overflowSamples += dropped
                state.maximumTapDurationMs = max(state.maximumTapDurationMs, elapsedMs)
            }
        }
    }

    private func handleTapFormatMismatch(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        generation: Int
    ) {
        let shouldTriggerRestart = stateLock.withLock { state -> Bool in
            guard state.generation == generation, state.recording, !state.stopping else { return false }
            state.formatMismatchCount += 1
            if state.formatMismatchCount >= 3 {
                state.formatMismatchCount = 0
                return true
            }
            return false
        }
        guard shouldTriggerRestart else { return }
        RuntimeTelemetry.emitRuntimeEvent("audio_format_mismatch", fields: [
            "expected_hz": converter.inputFormat.sampleRate,
            "actual_hz": buffer.format.sampleRate,
            "generation": generation
        ])
        configurationQueue.async { [weak self] in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        // Do not schedule an engine rebuild here: a fresh AVAudioEngine on a
        // Bluetooth input triggers another route change, which would abort
        // every following session.
        let action = stateLock.withLock { state -> ConfigurationChangeAction in
            guard state.recording,
                  !state.stopping,
                  !state.interruptionReported else { return .ignore }

            if state.graphSetupInProgress {
                state.setupInvalidated = true
                return .ignore
            }

            guard state.tapInstalled else { return .ignore }
            state.acceptingSamples = false
            let canRestart = state.configurationRestarts < Self.maxConfigurationRestarts
            guard canRestart else {
                state.interruptionReported = true
                return .interrupt(state.callbacks)
            }
            state.configurationRestarts += 1
            return .restart(generation: state.generation)
        }
        switch action {
        case .ignore:
            return
        case let .interrupt(callbacks):
            callbacks.onCaptureInterrupted(.configurationChanged)
        case let .restart(generation):
            configurationQueue.async { [weak self] in
                self?.restartCaptureAfterConfigurationChange(generation: generation)
            }
        }
    }

    /// Rebuilds the tap and converter on the existing engine for the new input
    /// format. Reports an interruption only if the restart itself fails.
    private func restartCaptureAfterConfigurationChange(generation: Int) {
        let outcome: Result<Double, Error> = engineLock.withLock {
            guard isActiveRecording(generation: generation) else {
                return .failure(CancellationError())
            }
            stateLock.withLock { $0.acceptingSamples = false }
            tapWorkLock.withLock {}
            guard teardownEngineSetup() else {
                return .failure(AudioRecorderError.engineStartFailed("Teardown timed out"))
            }
            return Result { try setupAndStartEngine(generation: generation) }
        }
        switch outcome {
        case let .success(rate):
            let resumed = stateLock.withLock { state -> Bool in
                guard state.generation == generation, state.recording,
                      !state.stopping, !state.interruptionReported else { return false }
                state.acceptingSamples = true
                return true
            }
            log("Audio capture restarted after configuration change (input \(Int(rate)) Hz, resumed: \(resumed))")
            emitRestartTelemetry(generation: generation, outcome: "restarted")
        case let .failure(error):
            if error is CancellationError { return }
            log("Audio capture restart after configuration change failed: \(error.localizedDescription)")
            emitRestartTelemetry(generation: generation, outcome: "failed")
            reportConfigurationInterruption(generation: generation)
        }
    }

    private func isActiveRecording(generation: Int) -> Bool {
        stateLock.withLock {
            $0.generation == generation && $0.recording
                && !$0.stopping && !$0.interruptionReported
        }
    }

    private func reportConfigurationInterruption(generation: Int) {
        let callbacks = stateLock.withLock { state -> Callbacks? in
            guard state.generation == generation, state.recording,
                  !state.stopping, !state.interruptionReported else { return nil }
            state.acceptingSamples = false
            state.interruptionReported = true
            return state.callbacks
        }
        callbacks?.onCaptureInterrupted(.configurationChanged)
    }

    private func emitRestartTelemetry(generation: Int, outcome: String) {
        let attempt = stateLock.withLock { $0.configurationRestarts }
        RuntimeTelemetry.emitRuntimeEvent("audio_capture_restart", fields: [
            "generation": generation,
            "attempt": attempt,
            "outcome": outcome
        ])
    }

    // MARK: - Consumer task: VAD + chunking, off the audio thread

    private func startConsumer() {
        consumerTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while true {
                let produced = self.drainAndProcess()
                if Task.isCancelled { return }
                if !produced {
                    try? await Task.sleep(nanoseconds: 15_000_000) // 15 ms
                }
            }
        }
    }

    /// Pull available samples and process whole 30 ms VAD frames. Returns true if
    /// any samples were consumed this pass.
    private func drainAndProcess() -> Bool {
        let incoming = ringBuffer.read(maxCount: config.sampleRate) // up to 1 s per pass
        if incoming.isEmpty { return false }

        stateLock.withLock { state in
            guard state.recording else { return }
            state.pendingFrame.append(contentsOf: incoming)
            while state.pendingFrame.count >= frameSamples {
                let frame = Array(state.pendingFrame.prefix(frameSamples))
                state.pendingFrame.removeFirst(frameSamples)
                state.accumulation.append(contentsOf: frame)

                let speech = vad.isSpeech(frame)
                state.chunker.beginBlock(samples: frameSamples)
                state.chunker.voiceFrame(isSpeech: speech, seconds: 0.03)
                switch state.chunker.endBlock() {
                case .continue:
                    break
                case .emit:
                    let chunk = state.accumulation
                    state.accumulation.removeAll(keepingCapacity: true)
                    state.callbacks.onChunk(chunk)
                case .discard:
                    state.accumulation.removeAll(keepingCapacity: true)
                }
            }
        }
        return true
    }

    private func ensureStartIsActive(generation: Int) throws {
        try Task.checkCancellation()
        let active = stateLock.withLock {
            $0.generation == generation
                && $0.recording
                && !$0.stopping
                && !$0.interruptionReported
        }
        if !active { throw CancellationError() }
    }

    @discardableResult
    private func resetEngineIfAllowed() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let lastReset = stateLock.withLock { $0.lastEngineResetUptime }
        if now - lastReset < 10.0 {
            log("Throttling audio engine reset (last reset was \(String(format: "%.1f", now - lastReset))s ago)")
            return false
        }
        stateLock.withLock { $0.lastEngineResetUptime = now }
        log("Resetting audio engine due to hardware setup failure")
        engineAdapter.resetEngine()
        return true
    }

    private func resetEngineIfNeeded() {
        let reason = stateLock.withLock { state -> EngineResetReason in
            let r = state.engineResetReason
            state.engineResetReason = .none
            return r
        }
        guard reason != .none else { return }
        engineLock.withLock {
            _ = resetEngineIfAllowed()
        }
    }

    private func performEngineStart(generation: Int) throws -> Double {
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            stateLock.withLock { state in
                if state.generation == generation { state.setupInvalidated = false }
            }
            do {
                let rate = try engineLock.withLock {
                    try setupAndStartEngine(generation: generation)
                }
                let invalidated = stateLock.withLock {
                    $0.generation == generation && $0.setupInvalidated
                }
                if invalidated {
                    log("Audio configuration changed during setup, retrying (attempt \(attempts))...")
                    _ = engineLock.withLock { teardownEngineSetup() }
                    continue
                }
                return rate
            } catch let error as AudioRecorderError where error.isTapInstallFailure {
                return try retryAfterTapInstallFailure(generation: generation, originalError: error)
            }
        }
        throw AudioRecorderError.engineStartFailed("Configuration changed repeatedly during setup")
    }

    private func retryAfterTapInstallFailure(
        generation: Int,
        originalError: AudioRecorderError
    ) throws -> Double {
        let retryResult: Result<Double, Error> = engineLock.withLock {
            log("Audio tap installation failed (\(originalError.localizedDescription)), attempting engine reset and retry...")
            guard teardownEngineSetup() else {
                return .failure(AudioRecorderError.tapInstallFailed("Teardown timed out"))
            }
            _ = resetEngineIfAllowed()
            return Result { try setupAndStartEngine(generation: generation) }
        }
        switch retryResult {
        case let .success(rate):
            return rate
        case let .failure(finalError):
            scheduleGraphTeardownIfNeeded(generation: generation)
            resetFailedStart(generation: generation, reason: .tapInstallFailure)
            throw finalError
        }
    }

    private func awaitValidInputFormat(
        timeout: TimeInterval = 0.5,
        pollInterval: TimeInterval = 0.05
    ) throws -> AudioInputFormatSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let snapshot = engineAdapter.inputFormatSnapshot()
            if snapshot.sampleRate > 0 && snapshot.channelCount > 0 {
                return snapshot
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw AudioRecorderError.invalidInputFormat(
                    sampleRate: snapshot.sampleRate,
                    channels: snapshot.channelCount
                )
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private func setupAndStartEngine(generation: Int) throws -> Double {
        try ensureStartIsActive(generation: generation)
        stateLock.withLock { state in
            if state.generation == generation { state.graphSetupInProgress = true }
        }
        let inputFormat = try awaitValidInputFormat()
        log("Input format snapshot: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
        guard let newConverter = engineAdapter.makeConverter(
            from: inputFormat,
            to: targetFormat
        ) else {
            throw AudioRecorderError.converterUnavailable
        }
        try ensureStartIsActive(generation: generation)
        converter = newConverter
        try engineAdapter.installTap(bufferSize: 1024, inputFormat: inputFormat) { [weak self] buffer in
            self?.handleTap(buffer, generation: generation)
        }
        stateLock.withLock { state in
            if state.generation == generation { state.tapInstalled = true }
        }
        try ensureStartIsActive(generation: generation)
        engineAdapter.prepare()
        try ensureStartIsActive(generation: generation)
        do {
            try engineAdapter.start()
        } catch {
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
        try ensureStartIsActive(generation: generation)
        stateLock.withLock { state in
            if state.generation == generation { state.graphSetupInProgress = false }
        }
        return inputFormat.sampleRate
    }

    @discardableResult
    private func teardownEngineSetup() -> Bool {
        let completed = closeWatchdog.closeAndWait { [engineAdapter] in
            engineAdapter.removeTap()
            engineAdapter.stop()
        }
        converter = nil
        stateLock.withLock { state in
            state.tapInstalled = false
            state.graphSetupInProgress = false
        }
        return completed
    }

    private func resetFailedStart(generation: Int, reason: EngineResetReason = .none) {
        stateLock.withLock { state in
            guard state.generation == generation else { return }
            state.recording = false
            state.stopping = false
            state.acceptingSamples = false
            state.tapInstalled = false
            state.graphSetupInProgress = false
            state.interruptionReported = false
            state.engineResetReason = reason
            state.callbacks = Callbacks()
        }
        converter = nil
    }

    private func scheduleGraphTeardownIfNeeded(generation: Int) {
        let shouldRemoveTap: Bool? = engineLock.withLock {
            stateLock.withLock { state -> Bool? in
                guard state.generation == generation,
                      state.tapInstalled,
                      !state.teardownStarted else { return nil }
                state.teardownStarted = true
                state.graphSetupInProgress = false
                state.tapInstalled = false
                return true
            }
        }
        guard let shouldRemoveTap else { return }

        // A callback that passed the accepting-samples check owns this lock until
        // its converted samples are in the ring. Once acquired here, no sample
        // from this generation can appear after the final drain.
        tapWorkLock.withLock {}
        // Both potentially blocking graph teardown steps run under one watchdog.
        closeWatchdog.close { [engineAdapter] in
            if shouldRemoveTap { engineAdapter.removeTap() }
            engineAdapter.stop()
        }
    }

    private func emitPendingAudioTelemetry(generation: Int) {
        let stats = stateLock.withLock { state in
            (state.overflowSamples, state.maximumTapDurationMs)
        }
        RuntimeTelemetry.emitRuntimeEvent("audio_capture_stats", fields: [
            "generation": generation,
            "overflow_samples": stats.0,
            "maximum_callback_ms": stats.1
        ])
    }
}

/// Feeds a single input buffer to `AVAudioConverter.convert` exactly once, then
/// reports no-more-data.
///
/// @unchecked Sendable: `AVAudioConverter`'s input block is typed `@Sendable`,
/// but it is invoked synchronously and inline within a single `convert(to:)`
/// call on the calling thread — there is no concurrent access to this feeder.
private final class SingleBufferFeeder: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var fed = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if fed {
            status.pointee = .noDataNow
            return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
    }
}
