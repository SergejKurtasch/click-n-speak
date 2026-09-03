import AVFoundation
import CoreMedia
import Foundation

enum MediaAudioDecoderError: Error, Sendable {
    case unsupportedMedia
    case noAudioTrack
    case readerCreation
    case readerStart
    case decodeFailed
    case invalidPCMBuffer
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
    private var pending: [Float] = []
    private var reachedEnd = false

    private init(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        estimatedSegmentCount: Int?,
        segmentSamples: Int
    ) {
        self.reader = reader
        self.output = output
        self.estimatedSegmentCount = estimatedSegmentCount
        self.segmentSamples = segmentSamples
    }

    static func open(
        url: URL,
        segmentSamples: Int = defaultSegmentSamples
    ) async throws -> MediaAudioSegmentReader {
        guard FileMediaType.detect(url: url, header: try? readHeader(url)) != nil else {
            throw MediaAudioDecoderError.unsupportedMedia
        }
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
            segmentSamples: segmentSamples
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
        return try handle.read(upToCount: 16) ?? Data()
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
