@preconcurrency import AVFoundation
import Foundation
import os

/// Captures microphone audio via AVAudioEngine and emits speech chunks.
///
/// Ported from `recorder.py` with the §4.5 restructure: the tap does nothing but
/// convert to 16 kHz mono and write into a `SampleRingBuffer`; a consumer task
/// runs the VAD and `AudioChunker` off the audio thread. Chunk thresholds and
/// the final-chunk guard are preserved 1:1.
public enum RecorderError: Error {
    /// The previous stream never finished tearing down — Core Audio is wedged and
    /// the app restarts instead of opening a stream that would capture nothing.
    case previousStreamStuck
}

public final class AudioRecorder: @unchecked Sendable {
    public struct Callbacks: Sendable {
        /// A non-final speech chunk (16 kHz mono float32).
        public var onChunk: @Sendable ([Float]) -> Void
        /// The final chunk on stop (already passed the 0.3 s guard), or nil.
        public var onFinal: @Sendable ([Float]?) -> Void

        public init(
            onChunk: @escaping @Sendable ([Float]) -> Void = { _ in },
            onFinal: @escaping @Sendable ([Float]?) -> Void = { _ in }
        ) {
            self.onChunk = onChunk
            self.onFinal = onFinal
        }
    }

    private let config: ChunkingConfig
    private let vad: VoiceActivityDetecting
    private let log: @Sendable (String) -> Void
    private let playsSounds: Bool
    private let closeWatchdog: StreamCloseWatchdog

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let ringBuffer: SampleRingBuffer

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var recording = false
        var callbacks = Callbacks()
        var chunker = AudioChunker()
        var accumulation: [Float] = []   // samples for the current (non-emitted) chunk
        var pendingFrame: [Float] = []    // leftover < one VAD frame
    }
    private var consumerTask: Task<Void, Never>?

    private let frameSamples: Int  // VAD frame size (30 ms)

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
        playsSounds: Bool = true,
        streamCloseTimeout: TimeInterval = 12.0,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onFatalError: @escaping @Sendable () -> Void = {}
    ) {
        self.config = config
        self.vad = vad
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
    }

    public var isRecording: Bool {
        stateLock.withLock { $0.recording }
    }

    // MARK: - Start / stop

    /// Async because of the start cue: the beep plays *before* the input opens and
    /// we wait it out so it is not recorded (`play_sound` + `time.sleep(0.2)` in
    /// `recorder.start`). Suspending keeps that wait off the caller's thread.
    public func start(callbacks: Callbacks) async throws {
        let alreadyRecording: Bool = stateLock.withLock { state in
            if state.recording { return true }
            state.recording = true
            state.callbacks = callbacks
            state.chunker = AudioChunker(config: config)
            state.accumulation.removeAll(keepingCapacity: true)
            state.pendingFrame.removeAll(keepingCapacity: true)
            return false
        }
        if alreadyRecording { return }
        ringBuffer.clear()

        // A stream still tearing down holds Core Audio state; opening a new one on
        // top of it either deadlocks or yields a stream that captures nothing.
        guard await closeWatchdog.awaitPendingClose() else {
            stateLock.withLock { $0.recording = false }
            throw RecorderError.previousStreamStuck
        }

        if playsSounds {
            RecordingSounds.playStart()
            try? await Task.sleep(nanoseconds: UInt64(RecordingSounds.startSoundLeadTime * 1_000_000_000))
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            stateLock.withLock { $0.recording = false }
            throw error
        }
        startConsumer()
        log("AudioRecorder started (input \(Int(inputFormat.sampleRate)) Hz → \(config.sampleRate) Hz)")
    }

    /// Stop recording. Drains the buffer, applies the final-chunk guard, and
    /// delivers the final chunk via `onFinal`.
    public func stop() {
        let callbacks: Callbacks? = stateLock.withLock { state -> Callbacks? in
            guard state.recording else { return nil }
            state.recording = false
            return state.callbacks
        }
        guard let callbacks else { return }

        engine.inputNode.removeTap(onBus: 0)
        // Tear the engine down off this thread, watched for hangs: `recording` is
        // already false, so the tap cannot mutate state after we return.
        closeWatchdog.close { [engine] in engine.stop() }
        consumerTask?.cancel()
        consumerTask = nil

        if playsSounds { RecordingSounds.playStop() }

        // Drain whatever remains and assemble the final chunk.
        let remaining = ringBuffer.readAll()
        let finalChunk: [Float] = stateLock.withLock { state in
            state.accumulation.append(contentsOf: state.pendingFrame)
            state.accumulation.append(contentsOf: remaining)
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
    }

    // MARK: - Tap (audio thread): convert + write only

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let feeder = SingleBufferFeeder(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            feeder.next(inputStatus)
        }
        guard status != .error, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        if count > 0 {
            ringBuffer.write(Array(UnsafeBufferPointer(start: channel, count: count)))
        }
    }

    // MARK: - Consumer task: VAD + chunking, off the audio thread

    private func startConsumer() {
        consumerTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let produced = self.drainAndProcess()
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
