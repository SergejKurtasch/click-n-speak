import AVFoundation
import CoreMedia
import Darwin
import Foundation

enum MediaAudioDecoderError: Error, Sendable {
    case unsupportedMedia
    case noAudioTrack
    case readerCreation
    case readerStart
    case decodeFailed
    case invalidPCMBuffer
    case conversionFailed
    case conversionTimedOut
}

final class TemporaryMediaArtifact: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private let lock = NSLock()
    private var cleaned = false

    init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    func cleanup() {
        let shouldClean = lock.withLock { () -> Bool in
            guard !cleaned else { return false }
            cleaned = true
            return true
        }
        if shouldClean {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit {
        cleanup()
    }
}

private final class ConversionProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminationScheduled = false

    func install(_ process: Process) {
        lock.withLock {
            self.process = process
            terminationScheduled = false
        }
    }

    func clear() {
        lock.withLock {
            process = nil
            terminationScheduled = false
        }
    }

    func terminateAndEscalate(graceSeconds: TimeInterval = 0.2) {
        let target = lock.withLock { () -> (Process, pid_t)? in
            guard !terminationScheduled, let process, process.isRunning else { return nil }
            terminationScheduled = true
            return (process, process.processIdentifier)
        }
        guard let (runningProcess, processID) = target else { return }
        runningProcess.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + graceSeconds) { [self] in
            let shouldKill = lock.withLock {
                process?.processIdentifier == processID && process?.isRunning == true
            }
            if shouldKill {
                _ = Darwin.kill(processID, SIGKILL)
            }
        }
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        let waiter = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            if let continuation {
                self.continuation = nil
                return continuation
            }
            self.status = status
            return nil
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { waiter in
            let completed = lock.withLock { () -> Int32? in
                if let status { return status }
                continuation = waiter
                return nil
            }
            if let completed {
                waiter.resume(returning: completed)
            }
        }
    }
}

private enum ConversionWaitOutcome: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
}

enum CoreAudioConverter {
    static func convertToWAV(
        sourceURL: URL,
        timeout: Duration = .seconds(300),
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/afconvert"),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        arguments: (@Sendable (URL, URL) -> [String])? = nil
    ) async throws -> TemporaryMediaArtifact {
        let directory = temporaryRoot
            .appendingPathComponent("click-n-speak-media-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("converted.wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = TemporaryMediaArtifact(url: outputURL, directory: directory)
        let state = ConversionProcessState()

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let process = Process()
                let completion = ProcessCompletion()
                process.executableURL = executableURL
                process.arguments = arguments?(sourceURL, outputURL) ?? [
                    sourceURL.path,
                    outputURL.path,
                    "-f", "WAVE",
                    "-d", "LEI16@16000",
                    "-c", "1"
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { completed in
                    completion.finish(completed.terminationStatus)
                }
                state.install(process)
                try process.run()

                let outcome = await withTaskGroup(of: ConversionWaitOutcome.self) { group in
                    group.addTask { .exited(await completion.wait()) }
                    group.addTask {
                        do {
                            try await Task.sleep(for: timeout)
                            return .timedOut
                        } catch {
                            return .cancelled
                        }
                    }
                    let first = await group.next() ?? .cancelled
                    if case .exited = first {
                        group.cancelAll()
                    } else {
                        state.terminateAndEscalate()
                    }
                    return first
                }
                state.clear()
                if Task.isCancelled {
                    throw CancellationError()
                }
                switch outcome {
                case .exited(0):
                    guard FileManager.default.fileExists(atPath: outputURL.path) else {
                        throw MediaAudioDecoderError.conversionFailed
                    }
                    return artifact
                case .exited:
                    throw MediaAudioDecoderError.conversionFailed
                case .timedOut:
                    throw MediaAudioDecoderError.conversionTimedOut
                case .cancelled:
                    throw CancellationError()
                }
            } onCancel: {
                state.terminateAndEscalate()
            }
        } catch {
            state.terminateAndEscalate()
            artifact.cleanup()
            throw error
        }
    }
}

/// Pull-based AVFoundation decoder. Each call yields at most one 30-second
/// 16 kHz mono Float32 segment, so one-hour media never becomes one giant audio
/// allocation. It is consumed from a transcriber actor, never MainActor.
final class MediaAudioSegmentReader: @unchecked Sendable {
    static let sampleRate = 16_000
    static let defaultSegmentSamples = sampleRate * 30

    let estimatedSegmentCount: Int?
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let segmentSamples: Int
    private let temporaryArtifact: TemporaryMediaArtifact?
    private var pending: [Float] = []
    private var reachedEnd = false

    var usesTemporaryConversion: Bool { temporaryArtifact != nil }
    var temporaryConversionURL: URL? { temporaryArtifact?.url }

    private init(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        estimatedSegmentCount: Int?,
        segmentSamples: Int,
        temporaryArtifact: TemporaryMediaArtifact?
    ) {
        self.reader = reader
        self.output = output
        self.estimatedSegmentCount = estimatedSegmentCount
        self.segmentSamples = segmentSamples
        self.temporaryArtifact = temporaryArtifact
    }

    static func open(
        url: URL,
        segmentSamples: Int = defaultSegmentSamples
    ) async throws -> MediaAudioSegmentReader {
        guard let mediaType = FileMediaType.detect(url: url, header: try? readHeader(url)) else {
            throw MediaAudioDecoderError.unsupportedMedia
        }
        switch MediaFormatCapabilities.policy(for: mediaType) {
        case .unsupported:
            throw MediaAudioDecoderError.unsupportedMedia
        case .coreAudioConversion:
            let artifact = try await CoreAudioConverter.convertToWAV(sourceURL: url)
            return try await openNative(
                url: artifact.url,
                segmentSamples: segmentSamples,
                temporaryArtifact: artifact
            )
        case .nativeDecode:
            return try await openNative(url: url, segmentSamples: segmentSamples)
        }
    }

    private static func openNative(
        url: URL,
        segmentSamples: Int,
        temporaryArtifact: TemporaryMediaArtifact? = nil
    ) async throws -> MediaAudioSegmentReader {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaAudioDecoderError.noAudioTrack
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaAudioDecoderError.readerCreation
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaAudioDecoderError.readerCreation }
        reader.add(output)
        guard reader.startReading() else { throw MediaAudioDecoderError.readerStart }

        let duration = try? await asset.load(.duration)
        let seconds = duration.flatMap { value -> Double? in
            let seconds = CMTimeGetSeconds(value)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        let total = seconds.map {
            max(1, Int(ceil($0 * Double(sampleRate) / Double(segmentSamples))))
        }
        return MediaAudioSegmentReader(
            reader: reader,
            output: output,
            estimatedSegmentCount: total,
            segmentSamples: segmentSamples,
            temporaryArtifact: temporaryArtifact
        )
    }

    func nextSegment() throws -> [Float]? {
        try Task.checkCancellation()
        while pending.count < segmentSamples && !reachedEnd {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                reachedEnd = true
                if reader.status == .failed { throw MediaAudioDecoderError.decodeFailed }
                break
            }
            pending.append(contentsOf: try Self.floatSamples(from: sampleBuffer))
        }
        guard !pending.isEmpty else { return nil }
        let count = min(segmentSamples, pending.count)
        let segment = Array(pending.prefix(count))
        pending.removeFirst(count)
        return segment
    }

    func cancel() {
        reader.cancelReading()
        pending.removeAll(keepingCapacity: false)
        reachedEnd = true
        temporaryArtifact?.cleanup()
    }

    private static func floatSamples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw MediaAudioDecoderError.invalidPCMBuffer
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
            throw MediaAudioDecoderError.invalidPCMBuffer
        }
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw MediaAudioDecoderError.invalidPCMBuffer
        }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    private static func readHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 64) ?? Data()
    }
}

enum FileTranscriptAssembler {
    static func join(_ segments: [String]) -> String {
        segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
