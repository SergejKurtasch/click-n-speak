@preconcurrency import AVFoundation
import CNSCore
import Foundation
import Testing
import CNSObjCExceptionCatcher
@testable import CNSAudio

@Suite("AudioRecorder lifecycle validation")
struct AudioRecorderLifecycleTests {
    private final class FakeAudioEngineAdapter: AudioEngineAdapting, @unchecked Sendable {
        private let lock = NSLock()
        var inputSampleRate: Double
        var inputChannelCount: Int
        var formatSequence: [AudioInputFormatSnapshot] = []
        var converterAvailable = true
        var configurationChangeDuringConverter = false
        var configurationChangeDuringConverterTimes = 0
        var startError: Error?
        var installTapError: Error?
        var failInstallTapTimes = 0
        var removeTapDelay: TimeInterval = 0
        private(set) var installTapCount = 0
        private(set) var removeTapCount = 0
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var resetEngineCount = 0
        private var tapHandlers: [@Sendable (AVAudioPCMBuffer) -> Void] = []
        private var configurationChangeHandler: (@Sendable () -> Void)?

        init(sampleRate: Double = 48_000, channels: Int = 1) {
            inputSampleRate = sampleRate
            inputChannelCount = channels
        }

        func inputFormatSnapshot() -> AudioInputFormatSnapshot {
            lock.withLock {
                if !formatSequence.isEmpty {
                    return formatSequence.removeFirst()
                }
                return AudioInputFormatSnapshot(
                    sampleRate: inputSampleRate,
                    channelCount: inputChannelCount
                )
            }
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
            if configurationChangeDuringConverterTimes > 0 {
                configurationChangeDuringConverterTimes -= 1
                inputSampleRate = 44_100
                emitConfigurationChange()
            } else if configurationChangeDuringConverter {
                inputSampleRate = 44_100
                emitConfigurationChange()
            }
            return converter
        }

        func installTap(
            bufferSize: AVAudioFrameCount,
            inputFormat: AudioInputFormatSnapshot,
            handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
        ) throws {
            try lock.withLock {
                installTapCount += 1
                if failInstallTapTimes > 0 {
                    failInstallTapTimes -= 1
                    throw installTapError ?? AudioRecorderError.tapInstallFailed("Simulated tap failure")
                }
                if let installTapError {
                    throw installTapError
                }
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
        func resetEngine() { lock.withLock { resetEngineCount += 1 } }

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

        func emitBufferWithFormat(sampleRate: Double, channels: Int) {
            let handler = lock.withLock { tapHandlers.last }
            guard let handler,
                  let format = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels)
                  ),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return }
            buffer.frameLength = 512
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

    @Test("A configuration change during setup retries and successfully starts")
    func configurationChangeDuringSetupRetriesAndSucceeds() async throws {
        let adapter = FakeAudioEngineAdapter()
        adapter.configurationChangeDuringConverterTimes = 1
        let interruptions = InterruptionBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        try await recorder.start(callbacks: .init(
            onCaptureInterrupted: { interruptions.append($0) }
        ))

        #expect(interruptions.snapshot.isEmpty)
        #expect(recorder.isRecording)
        #expect(adapter.installTapCount == 2)
        #expect(adapter.startCount == 2)
        #expect(adapter.resetEngineCount == 0)
        await recorder.stop()
    }

    @Test("Persistent configuration change during setup throws after max attempts")
    func persistentConfigurationChangeDuringSetupThrows() async {
        let adapter = FakeAudioEngineAdapter()
        adapter.configurationChangeDuringConverter = true
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        await #expect(throws: AudioRecorderError.self) {
            try await recorder.start(callbacks: .init())
        }

        #expect(recorder.isRecording == false)
        #expect(adapter.installTapCount == 3)
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
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(fatal.isSet)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(adapter.removeTapCount == 1)
        #expect(adapter.stopCount == 1)
    }

    @Test("Configuration change during recording restarts capture in place")
    func configurationChangeRestartsCaptureInPlace() async throws {
        let adapter = FakeAudioEngineAdapter()
        let interruptions = InterruptionBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)
        try await recorder.start(callbacks: .init(
            onCaptureInterrupted: { interruptions.append($0) }
        ))

        adapter.inputSampleRate = 16_000
        adapter.emitConfigurationChange()
        await settle()

        #expect(interruptions.snapshot.isEmpty)
        #expect(recorder.isRecording)
        #expect(adapter.installTapCount == 2)
        #expect(adapter.startCount == 2)
        #expect(adapter.resetEngineCount == 0)

        await recorder.stop()
        await settle()
        #expect(adapter.removeTapCount == 2)
        #expect(adapter.stopCount == 2)

        try await recorder.start(callbacks: .init())
        await recorder.stop()
        #expect(adapter.installTapCount == 3)
        #expect(adapter.resetEngineCount == 0)
    }

    @Test("A failed in-place restart reports one configuration interruption")
    func failedRestartReportsInterruption() async throws {
        let adapter = FakeAudioEngineAdapter()
        let interruptions = InterruptionBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)
        try await recorder.start(callbacks: .init(
            onCaptureInterrupted: { interruptions.append($0) }
        ))

        adapter.startError = StartFailure.failed
        adapter.emitConfigurationChange()
        await settle()

        #expect(interruptions.snapshot == [.configurationChanged])
        await recorder.stop()
        await recorder.stop()
        #expect(recorder.isRecording == false)
    }

    @Test("Repeated configuration changes stop restarting after the per-session cap")
    func restartCapReportsInterruption() async throws {
        let adapter = FakeAudioEngineAdapter()
        let interruptions = InterruptionBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)
        try await recorder.start(callbacks: .init(
            onCaptureInterrupted: { interruptions.append($0) }
        ))

        for _ in 0...AudioRecorder.maxConfigurationRestarts {
            adapter.emitConfigurationChange()
            await settle()
        }

        #expect(interruptions.snapshot == [.configurationChanged])
        #expect(adapter.installTapCount == 1 + AudioRecorder.maxConfigurationRestarts)
        await recorder.stop()
    }

    @Test("Bluetooth route switch on every start never rebuilds the engine")
    func routeSwitchOnEveryStartDoesNotLoop() async throws {
        let adapter = FakeAudioEngineAdapter(sampleRate: 16_000)
        let interruptions = InterruptionBox()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        for _ in 0..<3 {
            try await recorder.start(callbacks: .init(
                onCaptureInterrupted: { interruptions.append($0) }
            ))
            adapter.emitConfigurationChange()
            await settle()
            #expect(recorder.isRecording)
            await recorder.stop()
            await settle()
        }

        #expect(interruptions.snapshot.isEmpty)
        #expect(adapter.resetEngineCount == 0)
        #expect(adapter.installTapCount == 6)
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

    @Test("An installTap failure triggers engine reset and succeeds on retry")
    func installTapFailureRetriesAfterReset() async throws {
        let adapter = FakeAudioEngineAdapter()
        adapter.failInstallTapTimes = 1
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        try await recorder.start(callbacks: .init())
        #expect(recorder.isRecording)
        #expect(adapter.installTapCount == 2)
        #expect(adapter.resetEngineCount == 1)
        await recorder.stop()
    }

    @Test("A permanent installTap failure throws tapInstallFailed error")
    func installTapPermanentFailureThrows() async {
        let adapter = FakeAudioEngineAdapter()
        adapter.installTapError = AudioRecorderError.tapInstallFailed("Simulated persistent crash")
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        await #expect(throws: AudioRecorderError.tapInstallFailed("Simulated persistent crash")) {
            try await recorder.start(callbacks: .init())
        }
        #expect(recorder.isRecording == false)
        #expect(adapter.installTapCount == 2)
        #expect(adapter.resetEngineCount == 1)
    }

    @Test("Configuration change in idle does not rebuild the engine on next start")
    func configurationChangeInIdleDoesNotResetEngine() async throws {
        let adapter = FakeAudioEngineAdapter()
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        adapter.emitConfigurationChange()
        try await recorder.start(callbacks: .init())
        #expect(adapter.resetEngineCount == 0)
        #expect(recorder.isRecording)
        await recorder.stop()
    }

    @Test("Transient zero format during setup is awaited and succeeds")
    func transientZeroFormatIsAwaited() async throws {
        let adapter = FakeAudioEngineAdapter()
        adapter.formatSequence = [
            AudioInputFormatSnapshot(sampleRate: 0, channelCount: 0),
            AudioInputFormatSnapshot(sampleRate: 16_000, channelCount: 1)
        ]
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)
        try await recorder.start(callbacks: .init())
        #expect(recorder.isRecording)
        await recorder.stop()
    }

    @Test("Engine reset is rate limited to once per 10 seconds")
    func engineResetIsRateLimited() async throws {
        let adapter = FakeAudioEngineAdapter()
        adapter.failInstallTapTimes = 1
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)

        try await recorder.start(callbacks: .init())
        #expect(adapter.resetEngineCount == 1)
        await recorder.stop()

        adapter.failInstallTapTimes = 1
        try await recorder.start(callbacks: .init())
        #expect(adapter.resetEngineCount == 1)
        await recorder.stop()
    }

    @Test("Teardown hang during restart triggers onFatalError")
    func teardownHangDuringRestartTriggersFatalError() async throws {
        let adapter = FakeAudioEngineAdapter()
        let fatal = Flag()
        let recorder = AudioRecorder(
            engineAdapter: adapter,
            playsSounds: false,
            streamCloseTimeout: 0.05,
            onFatalError: { fatal.set() }
        )
        try await recorder.start(callbacks: .init())

        adapter.removeTapDelay = 0.2
        adapter.emitConfigurationChange()
        for _ in 0..<20 {
            if fatal.isSet { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fatal.isSet)
        await recorder.stop()
    }

    @Test("Tap format mismatch triggers in-place restart")
    func tapFormatDriftTriggersRestart() async throws {
        let adapter = FakeAudioEngineAdapter(sampleRate: 48_000, channels: 1)
        let recorder = AudioRecorder(engineAdapter: adapter, playsSounds: false)
        try await recorder.start(callbacks: .init())

        #expect(adapter.installTapCount == 1)
        for _ in 0..<3 {
            adapter.emitBufferWithFormat(sampleRate: 16_000, channels: 1)
        }
        for _ in 0..<20 {
            if adapter.installTapCount >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(adapter.installTapCount >= 2)
        await recorder.stop()
    }

    @Test("CNSObjCExceptionCatcher catches NSException and throws Error")
    func objcExceptionCatcher() {
        #expect(throws: (any Error).self) {
            try CNSObjCExceptionCatcher.perform {
                NSException(name: NSExceptionName("TestAudioException"), reason: "TestAudioReason", userInfo: nil).raise()
            }
        }
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
