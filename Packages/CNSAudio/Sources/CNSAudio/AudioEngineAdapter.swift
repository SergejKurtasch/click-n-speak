@preconcurrency import AVFoundation
import Foundation

public struct AudioInputFormatSnapshot: @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let nativeFormat: AVAudioFormat?

    public init(
        sampleRate: Double,
        channelCount: Int,
        nativeFormat: AVAudioFormat? = nil
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.nativeFormat = nativeFormat
    }

    init(_ format: AVAudioFormat) {
        self.init(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            nativeFormat: format
        )
    }
}

public protocol AudioEngineAdapting: AnyObject, Sendable {
    func inputFormatSnapshot() -> AudioInputFormatSnapshot
    func makeConverter(
        from inputFormat: AudioInputFormatSnapshot,
        to targetFormat: AVAudioFormat
    ) -> AVAudioConverter?
    func installTap(
        bufferSize: AVAudioFrameCount,
        inputFormat: AudioInputFormatSnapshot,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    )
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void)
}

final class AVAudioEngineAdapter: AudioEngineAdapting, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let notificationCenter: NotificationCenter
    private let handlerLock = NSLock()
    private var configurationChangeHandler: (@Sendable () -> Void)?
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            let handler = self?.handlerLock.withLock { self?.configurationChangeHandler }
            handler?()
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    func inputFormatSnapshot() -> AudioInputFormatSnapshot {
        AudioInputFormatSnapshot(engine.inputNode.outputFormat(forBus: 0))
    }

    func makeConverter(
        from inputFormat: AudioInputFormatSnapshot,
        to targetFormat: AVAudioFormat
    ) -> AVAudioConverter? {
        guard let nativeFormat = inputFormat.nativeFormat else { return nil }
        return AVAudioConverter(from: nativeFormat, to: targetFormat)
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        inputFormat: AudioInputFormatSnapshot,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        guard let nativeFormat = inputFormat.nativeFormat else { return }
        let input = engine.inputNode
        input.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: nativeFormat
        ) { buffer, _ in
            handler(buffer)
        }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        handlerLock.withLock { configurationChangeHandler = handler }
    }
}
