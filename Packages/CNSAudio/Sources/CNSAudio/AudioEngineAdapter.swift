@preconcurrency import AVFoundation
import Foundation
import CNSObjCExceptionCatcher

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
    ) throws
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    func resetEngine()
    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void)
}

public extension AudioEngineAdapting {
    func resetEngine() {}
}

final class AVAudioEngineAdapter: AudioEngineAdapting, @unchecked Sendable {
    private var engine: AVAudioEngine
    private let notificationCenter: NotificationCenter
    private let handlerLock = NSLock()
    private var configurationChangeHandler: (@Sendable () -> Void)?
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        let initialEngine = AVAudioEngine()
        self.engine = initialEngine
        self.observer = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: initialEngine,
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

    func resetEngine() {
        handlerLock.withLock {
            if let observer {
                notificationCenter.removeObserver(observer)
                self.observer = nil
            }
            engine.stop()
            let newEngine = AVAudioEngine()
            self.engine = newEngine
            self.observer = notificationCenter.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: newEngine,
                queue: nil
            ) { [weak self] _ in
                let handler = self?.handlerLock.withLock { self?.configurationChangeHandler }
                handler?()
            }
        }
    }

    func inputFormatSnapshot() -> AudioInputFormatSnapshot {
        let input = handlerLock.withLock { engine.inputNode }
        return AudioInputFormatSnapshot(input.outputFormat(forBus: 0))
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
    ) throws {
        guard let nativeFormat = inputFormat.nativeFormat else { return }
        let input = handlerLock.withLock { engine.inputNode }

        // Defensively remove any lingering tap on bus 0 before installing
        _ = try? CNSObjCExceptionCatcher.perform {
            input.removeTap(onBus: 0)
        }

        do {
            try CNSObjCExceptionCatcher.perform {
                input.installTap(
                    onBus: 0,
                    bufferSize: bufferSize,
                    format: nativeFormat
                ) { buffer, _ in
                    handler(buffer)
                }
            }
        } catch {
            throw AudioRecorderError.tapInstallFailed(error.localizedDescription)
        }
    }

    func removeTap() {
        let input = handlerLock.withLock { engine.inputNode }
        _ = try? CNSObjCExceptionCatcher.perform {
            input.removeTap(onBus: 0)
        }
    }

    func prepare() {
        handlerLock.withLock { engine.prepare() }
    }

    func start() throws {
        let currentEngine = handlerLock.withLock { engine }
        try currentEngine.start()
    }

    func stop() {
        handlerLock.withLock { engine.stop() }
    }

    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        handlerLock.withLock { configurationChangeHandler = handler }
    }
}
