@preconcurrency import AVFoundation
import CNSCore
import Foundation
import Testing
@testable import CNSAudio

@Suite("AudioRecorder lifecycle validation")
struct AudioRecorderLifecycleTests {
    private final class FakeAudioEngineAdapter: AudioEngineAdapting, @unchecked Sendable {
        private let lock = NSLock()
        var inputSampleRate: Double
        var inputChannelCount: Int
        var converterAvailable = true
        var configurationChangeDuringConverter = false
        var startError: Error?
        var removeTapDelay: TimeInterval = 0
        private(set) var installTapCount = 0
        private(set) var removeTapCount = 0
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private var tapHandlers: [@Sendable (AVAudioPCMBuffer) -> Void] = []
        private var configurationChangeHandler: (@Sendable () -> Void)?

        init(sampleRate: Double = 48_000, channels: Int = 1) {
            inputSampleRate = sampleRate
            inputChannelCount = channels
        }

        func inputFormatSnapshot() -> AudioInputFormatSnapshot {
            AudioInputFormatSnapshot(
                sampleRate: inputSampleRate,
                channelCount: inputChannelCount
            )
        }

        func makeConverter(
            from inputFormat: AudioInputFormatSnapshot,
            to targetFormat: AVAudioFormat
        ) -> AVAudioConverter? {
            guard converterAvailable,
                  let source = AVAudioFormat(
                    standardFormatWithSampleRate: max(inputFormat.sampleRate, 1),
                    channels: AVAudioChannelCount(max(inputFormat.channelCount, 1))
                  ) else { return nil }
            let converter = AVAudioConverter(from: source, to: targetFormat)
            if configurationChangeDuringConverter {
                inputSampleRate = 44_100
                emitConfigurationChange()
            }
            return converter
        }

        func installTap(
            bufferSize: AVAudioFrameCount,
            inputFormat: AudioInputFormatSnapshot,
            handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
        ) {
            lock.withLock {
                installTapCount += 1
                tapHandlers.append(handler)
            }
        }

        func removeTap() {
            lock.withLock { removeTapCount += 1 }
            if removeTapDelay > 0 { Thread.sleep(forTimeInterval: removeTapDelay) }
        }
        func prepare() {}
        func start() throws {
            lock.withLock { startCount += 1 }
            if let startError { throw startError }
        }
        func stop() { lock.withLock { stopCount += 1 } }

        func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { configurationChangeHandler = handler }
        }

        func emitConfigurationChange() {
            let handler = lock.withLock { configurationChangeHandler }
            handler?()
        }

        func emitLateBuffer(fromTapAt index: Int) {
            let handler = lock.withLock { tapHandlers[index] }
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1
            )!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_440)!
            buffer.frameLength = 1_440
            if let samples = buffer.floatChannelData?[0] {
                for offset in 0..<Int(buffer.frameLength) { samples[offset] = 0.25 }
            }
            handler(buffer)
        }
    }

    private final class InterruptionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AudioCaptureInterruption] = []

        func append(_ value: AudioCaptureInterruption) { lock.withLock { values.append(value) } }
        var snapshot: [AudioCaptureInterruption] { lock.withLock { values } }
    }

    private final class FinalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[Float]?] = []

        func append(_ value: [Float]?) { lock.withLock { values.append(value) } }
        var snapshot: [[Float]?] { lock.withLock { values } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test("Invalid input dimensions fail before installing a tap")
    func invalidInputFormat() {
        #expect(throws: AudioRecorderError.invalidInputFormat(sampleRate: 0, channels: 0)) {
            try AudioRecorder.validateInputFormat(sampleRate: 0, channels: 0)
        }
        #expect(throws: AudioRecorderError.invalidInputFormat(sampleRate: 48_000, channels: 0)) {
            try AudioRecorder.validateInputFormat(sampleRate: 48_000, channels: 0)
        }
    }

    @Test("A positive sample rate and channel count are accepted")
    func validInputFormat() {
        #expect(throws: Never.self) {
            try AudioRecorder.validateInputFormat(sampleRate: 48_000, channels: 2)
        }
    }

    @Test("Invalid adapter format and converter failure never install a tap")
    func controlledSetupFailures() async {
        let invalid = FakeAudioEngineAdapter(sampleRate: 0, channels: 0)
        let invalidRecorder = AudioRecorder(engineAdapter: invalid, playsSounds: false)
        await #expect(throws: AudioRecorderError.invalidInputFormat(sampleRate: 0, channels: 0)) {
            try await invalidRecorder.start(callbacks: .init())
        }
        #expect(invalid.installTapCount == 0)

        let missingConverter = FakeAudioEngineAdapter()
        missingConverter.converterAvailable = false
        let converterRecorder = AudioRecorder(engineAdapter: missingConverter, playsSounds: false)
        await #expect(throws: AudioRecorderError.converterUnavailable) {
            try await converterRecorder.start(callbacks: .init())
        }
        #expect(missingConverter.installTapCount == 0)
    }

    @Test("A configuration change during setup invalidates the format snapshot")
    func configurationChangeDuringSetup() async {
        let adapter = FakeAudioEngineAdapter()
        adapter.configurationChangeDuringConverter = true
        let interruptions = InterruptionBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        await #expect(throws: CancellationError.self) {
            try await recorder.start(callbacks: .init(
                onCaptureInterrupted: { interruptions.append($0) }
            ))
        }

        #expect(interruptions.snapshot == [.configurationChanged])
        #expect(adapter.installTapCount == 0)
        #expect(recorder.isRecording == false)
    }

    @Test("A post-install start failure tears down under the watchdog")
    func startFailureUsesWatchedTeardown() async {
        let adapter = FakeAudioEngineAdapter()
        adapter.startError = StartFailure.failed
        adapter.removeTapDelay = 0.2
        let fatal = Flag()
        let recorder = AudioRecorder(
            engineAdapter: adapter,
            playsSounds: false,
            streamCloseTimeout: 0.05,
            onFatalError: { fatal.set() }
        )

        let startedAt = Date()
        await #expect(throws: AudioRecorderError.self) {
            try await recorder.start(callbacks: .init())
        }
        #expect(Date().timeIntervalSince(startedAt) < 0.1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fatal.isSet)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(adapter.removeTapCount == 1)
        #expect(adapter.stopCount == 1)
    }

    @Test("Configuration change drains once and the next start rebuilds the graph")
    func configurationChangeRecovery() async throws {
        let adapter = FakeAudioEngineAdapter()
        let interruptions = InterruptionBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)
        try await recorder.start(callbacks: .init(
            onCaptureInterrupted: { interruptions.append($0) }
        ))

        adapter.emitConfigurationChange()
        await settle()
        await recorder.stop()
        await recorder.stop()

        #expect(interruptions.snapshot == [.configurationChanged])
        try await recorder.start(callbacks: .init())
        await recorder.stop()
        await settle()
        #expect(adapter.installTapCount == 2)
        #expect(adapter.removeTapCount == 2)
        #expect(adapter.startCount == 2)
        #expect(adapter.stopCount == 2)
    }

    @Test("A late tap from an old generation cannot enter the next recording")
    func lateTapIsGenerationScoped() async throws {
        let adapter = FakeAudioEngineAdapter()
        let finals = FinalBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        try await recorder.start(callbacks: .init(onFinal: { finals.append($0) }))
        await recorder.stop()
        try await recorder.start(callbacks: .init(onFinal: { finals.append($0) }))
        adapter.emitLateBuffer(fromTapAt: 0)
        await recorder.stop()

        #expect(finals.snapshot.count == 2)
        #expect(finals.snapshot.allSatisfy { $0 == nil })
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private enum StartFailure: Error {
    case failed
}
