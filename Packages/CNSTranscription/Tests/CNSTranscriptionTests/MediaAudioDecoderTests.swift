import Foundation
import Testing
@testable import CNSTranscription

@Suite("Media audio decoder")
struct MediaAudioDecoderTests {
    @Test("Pull decoder yields bounded segments in source order")
    func boundedSegments() async throws {
        let source = (0..<16_000).map { Float($0) / 16_000 }
        let wav = CloudSTTTranscriber.makeWAVData(from: source)
        let url = try makeTemporaryWAV(wav)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = try await MediaAudioSegmentReader.open(url: url, segmentSamples: 4_000)
        var segments: [[Float]] = []
        while let segment = try reader.nextSegment() { segments.append(segment) }

        #expect(segments.count == 4)
        #expect(segments.allSatisfy { $0.count <= 4_000 })
        #expect(segments.flatMap { $0 }.count == 16_000)
        #expect(segments[0][100] < segments[3][100])
    }

    @Test("Cancellation releases the reader without temporary artifacts")
    func cancellationAndCleanup() async throws {
        let wav = CloudSTTTranscriber.makeWAVData(
            from: [Float](repeating: 0.1, count: 16_000)
        )
        let url = try makeTemporaryWAV(wav)
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        let reader = try await MediaAudioSegmentReader.open(url: url, segmentSamples: 2_000)
        reader.cancel()

        #expect(try reader.nextSegment() == nil)
        #expect(try Data(contentsOf: url) == wav)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
    }

    @Test("Transcript assembly preserves segment order")
    func transcriptOrdering() {
        #expect(FileTranscriptAssembler.join([" first ", "second", "third "]) == "first second third")
    }

    private func makeTemporaryWAV(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}
