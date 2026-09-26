import Foundation
import CryptoKit
import Testing
@testable import CNSTranscription

@Suite("Media audio decoder")
struct MediaAudioDecoderTests {
    @Test("Supported fixture matrix decodes to bounded PCM without source mutation")
    func fixtureMatrix() async throws {
        for name in [
            "signal-16k-mono.wav",
            "signal-44k-mono.wav",
            "signal-48k-stereo.wav",
            "signal-48k-stereo.caf",
            "signal.m4a",
            "signal.aac"
        ] {
            let url = fixtureURL(name)
            let original = try Data(contentsOf: url)
            let checksum = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            let reader = try await MediaAudioSegmentReader.open(url: url, segmentSamples: 2_000)
            var sampleCount = 0
            while let samples = try reader.nextSegment() {
                #expect(!samples.isEmpty)
                #expect(samples.count <= 2_000)
                sampleCount += samples.count
            }
            #expect(sampleCount > 0, "Expected decoded samples for \(name)")
            #expect(try Data(contentsOf: url) == original)
            let afterChecksum = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(afterChecksum == checksum)
        }
    }

    @Test("Fixture checksums match the committed manifest")
    func fixtureChecksums() throws {
        let manifest = try String(contentsOf: fixtureURL("SHA256SUMS"), encoding: .utf8)
        let expected = Dictionary(uniqueKeysWithValues: manifest.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return (String(parts[1]), String(parts[0]))
        })
        #expect(!expected.isEmpty)
        for (name, checksum) in expected {
            let actual = SHA256.hash(data: try Data(contentsOf: fixtureURL(name)))
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(actual == checksum, "Checksum mismatch for \(name)")
        }
    }

    @Test("Raw AAC uses owned Core Audio conversion while unsupported Ogg fails early")
    func conversionAndUnsupportedPolicies() async throws {
        let aacReader = try await MediaAudioSegmentReader.open(url: fixtureURL("signal.aac"))
        #expect(aacReader.usesTemporaryConversion)
        let temporaryURL = try #require(aacReader.temporaryConversionURL)
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
        aacReader.cancel()
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))

        for name in ["signal.ogg", "signal.opus"] {
            do {
                _ = try await MediaAudioSegmentReader.open(url: fixtureURL(name))
                Issue.record("Expected unsupported media for \(name)")
            } catch MediaAudioDecoderError.unsupportedMedia {
                // Expected: the product does not depend on an installed third-party decoder.
            }
        }
    }

    @Test("Core Audio conversion cancellation waits for process exit and cleans its artifact")
    func conversionCancellation() async throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let startedAt = Date()
        let task = Task {
            try await CoreAudioConverter.convertToWAV(
                sourceURL: fixtureURL("signal.aac"),
                timeout: .seconds(30),
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                temporaryRoot: temporaryRoot,
                arguments: { _, _ in ["-c", "trap '' TERM; exec /bin/sleep 2"] }
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected conversion cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(Date().timeIntervalSince(startedAt) < 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path).isEmpty)
    }

    @Test("Core Audio conversion timeout terminates the process and cleans its artifact")
    func conversionTimeout() async throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        do {
            _ = try await CoreAudioConverter.convertToWAV(
                sourceURL: fixtureURL("signal.aac"),
                timeout: .milliseconds(50),
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                temporaryRoot: temporaryRoot,
                arguments: { _, _ in ["30"] }
            )
            Issue.record("Expected conversion timeout")
        } catch MediaAudioDecoderError.conversionTimedOut {
            // Expected.
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path).isEmpty)
    }

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
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("fixture.wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Media/\(name)")
    }
}
