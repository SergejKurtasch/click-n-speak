import CNSCore
import Foundation
import Testing
@testable import CNSTranscription

@Suite("Realtime Latency Benchmark")
struct RealtimeLatencyBenchmarkTests {
    private enum ManifestContractError: Error {
        case unsupportedBucket
        case emptyReference
    }

    private struct ManifestRow: Decodable {
        let id: String
        let lang: String
        let bucket: String
        let text: String
        let terms: [String]
        let audio: String
    }

    private struct OutputRow: Encodable {
        let schemaVersion = 1
        let adapter = "paced_pcm_direct"
        let caseID: String
        let modelID: String
        let modelChecksum: String
        let corpusChecksum: String
        let sampleID: String
        let sampleCount: Int
        let language: String
        let bucket: String
        let repetition: Int
        let repetitions: Int
        let temperature: String
        let languageMode: String
        let pipelineProfile: String
        let maxSpeechDuration: Double
        let captureDurationSeconds: Double
        let decodeDurationSeconds: Double
        let stopToTextSeconds: Double
        let totalDurationSeconds: Double
        let outcome: String
        let detectedLanguage: String
        let wordErrors: Int
        let referenceWordCount: Int
        let termHits: Int
        let termTotal: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case adapter
            case caseID = "case_id"
            case modelID = "model_id"
            case modelChecksum = "model_checksum"
            case corpusChecksum = "corpus_checksum"
            case sampleID = "sample_id"
            case sampleCount = "sample_count"
            case language
            case bucket
            case repetition
            case repetitions
            case temperature
            case languageMode = "language_mode"
            case pipelineProfile = "pipeline_profile"
            case maxSpeechDuration = "max_speech_duration"
            case captureDurationSeconds = "capture_duration_seconds"
            case decodeDurationSeconds = "decode_duration_seconds"
            case stopToTextSeconds = "stop_to_text_seconds"
            case totalDurationSeconds = "total_duration_seconds"
            case outcome
            case detectedLanguage = "detected_language"
            case wordErrors = "word_errors"
            case referenceWordCount = "reference_word_count"
            case termHits = "term_hits"
            case termTotal = "term_total"
        }
    }

    private enum Scoring {
        struct EmptyTermError: Error {}

        private static let numberWords: [String: Int] = [
            "один": 1, "одна": 1, "одного": 1, "два": 2, "две": 2, "двух": 2,
            "три": 3, "трех": 3, "четыре": 4, "четырех": 4, "пять": 5, "пяти": 5,
            "шесть": 6, "шести": 6, "семь": 7, "семи": 7, "восемь": 8, "восьми": 8,
            "девять": 9, "девяти": 9, "десять": 10, "десяти": 10,
            "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50,
            "сто": 100, "двести": 200, "триста": 300, "четыреста": 400, "пятьсот": 500,
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "twenty": 20, "thirty": 30, "fifty": 50, "hundred": 100,
        ]

        static func normalize(_ text: String) -> [String] {
            let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
                .replacingOccurrences(of: "-", with: " ")
            let scalars = lowered.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar)
                    ? Character(String(scalar))
                    : " "
            }
            let tokens = String(scalars).split(whereSeparator: \.isWhitespace).map(String.init)
            var output: [String] = []
            var index = 0
            while index < tokens.count {
                guard numberWords[tokens[index]] != nil else {
                    output.append(tokens[index])
                    index += 1
                    continue
                }
                var total = 0
                while index < tokens.count, let value = numberWords[tokens[index]] {
                    total += value
                    index += 1
                }
                output.append(String(total))
            }
            return output
        }

        static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
            guard !reference.isEmpty else { return hypothesis.count }
            var previous = Array(0 ... hypothesis.count)
            for (row, referenceWord) in reference.enumerated() {
                var current = [row + 1] + [Int](repeating: 0, count: hypothesis.count)
                for (column, hypothesisWord) in hypothesis.enumerated() {
                    current[column + 1] = min(
                        previous[column + 1] + 1,
                        current[column] + 1,
                        previous[column] + (referenceWord == hypothesisWord ? 0 : 1)
                    )
                }
                previous = current
            }
            return previous.last ?? reference.count
        }

        static func termHitCount(hypothesis: [String], terms: [String]) throws -> Int {
            var hits = 0
            for term in terms {
                let phrase = normalize(term)
                guard !phrase.isEmpty else { throw EmptyTermError() }
                guard phrase.count <= hypothesis.count else { continue }
                if (0 ... hypothesis.count - phrase.count).contains(where: { start in
                    hypothesis[start ..< start + phrase.count].elementsEqual(phrase)
                }) {
                    hits += 1
                }
            }
            return hits
        }
    }

    /// This package-level adapter deliberately measures a narrow, testable
    /// boundary: actual PCM is paced on a monotonic clock, then each forced
    /// maximum-duration segment is decoded serially. It does not claim to be
    /// AudioChunker/VAD or SessionController. A future app-level benchmark can
    /// replace the adapter without changing the JSONL orchestration contract.
    private struct PacedPCMAdapter {
        struct Capture {
            let audio: [Float]
            let duration: TimeInterval
        }

        let sampleRate = 16_000
        let frameSamples = 320

        func capture(_ audio: [Float]) async throws -> Capture {
            let clock = ContinuousClock()
            let startedAt = clock.now
            var captured: [Float] = []
            captured.reserveCapacity(audio.count)
            var offset = 0
            while offset < audio.count {
                let nextOffset = min(audio.count, offset + frameSamples)
                let elapsedNanoseconds = Int64(
                    (Double(nextOffset) / Double(sampleRate)) * 1_000_000_000
                )
                try await clock.sleep(
                    until: startedAt.advanced(by: .nanoseconds(elapsedNanoseconds))
                )
                captured.append(contentsOf: audio[offset ..< nextOffset])
                offset = nextOffset
            }
            return Capture(
                audio: captured,
                duration: Double(captured.count) / Double(sampleRate)
            )
        }

        func segments(_ audio: [Float], maximumDuration: Double) -> [[Float]] {
            let maximumSamples = max(1, Int(maximumDuration * Double(sampleRate)))
            return stride(from: 0, to: audio.count, by: maximumSamples).map { start in
                Array(audio[start ..< min(audio.count, start + maximumSamples)])
            }
        }
    }

    @Test("term scoring uses exact token and phrase boundaries")
    func termScoringUsesExactBoundaries() throws {
        #expect(try Scoring.termHitCount(hypothesis: ["github", "token"], terms: ["git"]) == 0)
        #expect(try Scoring.termHitCount(
            hypothesis: ["open", "initial", "prompt", "file"],
            terms: ["initial prompt"]
        ) == 1)
        #expect(throws: Scoring.EmptyTermError.self) {
            try Scoring.termHitCount(hypothesis: ["text"], terms: ["---"])
        }
    }

    @Test("manifest scoring contract rejects mutable quality denominators")
    func manifestScoringContractRejectsMutableQualityDenominators() throws {
        let valid = ManifestRow(
            id: "001",
            lang: "ru",
            bucket: "short",
            text: "Останови запись.",
            terms: [],
            audio: "001.wav"
        )
        #expect(try Self.validatedReference(for: valid) == ["останови", "запись"])
        #expect(throws: ManifestContractError.self) {
            try Self.validatedReference(for: ManifestRow(
                id: "001",
                lang: "ru",
                bucket: "tiny",
                text: valid.text,
                terms: [],
                audio: valid.audio
            ))
        }
        #expect(throws: ManifestContractError.self) {
            try Self.validatedReference(for: ManifestRow(
                id: "001",
                lang: "ru",
                bucket: "short",
                text: "---",
                terms: [],
                audio: valid.audio
            ))
        }
    }

    @Test("opt-in paced speech benchmark emits reproducible JSONL rows")
    func pacedSpeechBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CNS_LATENCY_BENCHMARKS"] == "1" else { return }

        let modelPath = try #require(environment["CNS_WHISPER_MODEL"])
        let modelID = try #require(environment["CNS_WHISPER_MODEL_ID"])
        let modelInfo = try #require(ModelRegistry.whisperModel(id: modelID))
        let modelURL = URL(fileURLWithPath: modelPath)
        #expect(modelURL.lastPathComponent == modelInfo.fileName)
        guard modelURL.lastPathComponent == modelInfo.fileName else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let corpusRoot = URL(fileURLWithPath: try #require(environment["CNS_STT_GOLDEN_DIR"]))
        let outputURL = URL(fileURLWithPath: try #require(environment["CNS_BENCHMARK_OUTPUT"]))
        let caseID = try #require(environment["CNS_BENCHMARK_CASE_ID"])
        let languageMode = try #require(environment["CNS_BENCHMARK_LANGUAGE_MODE"])
        let pipelineProfile = try #require(environment["CNS_BENCHMARK_PIPELINE_PROFILE"])
        let repetitions = try #require(
            environment["CNS_BENCHMARK_REPETITIONS"].flatMap(Int.init)
        )
        let sampleID = try #require(environment["CNS_BENCHMARK_SAMPLE_ID"])
        let repetition = try #require(
            environment["CNS_BENCHMARK_REPETITION"].flatMap(Int.init)
        )
        let temperature = try #require(environment["CNS_BENCHMARK_TEMPERATURE"])
        let maximumDuration = try #require(
            environment["CNS_BENCHMARK_MAX_SPEECH_DURATION"].flatMap(Double.init)
        )
        let modelChecksum = try #require(environment["CNS_BENCHMARK_MODEL_SHA256"])
        let corpusChecksum = try #require(environment["CNS_BENCHMARK_CORPUS_SHA256"])
        #expect(repetitions > 0)
        #expect(languageMode == "bilingual")
        let validObservation = (temperature == "cold" && repetition == 0)
            || (temperature == "warm" && (1 ... repetitions).contains(repetition))
        let validCase = switch caseID {
        case "B": modelID == "whisper-large-v3" && maximumDuration == 8
        case "C": modelID == "whisper-large-v3-turbo" && maximumDuration == 8
        case "D":
            ["whisper-large-v3", "whisper-large-v3-turbo"].contains(modelID)
                && maximumDuration == 6
        default: false
        }
        guard repetitions > 0,
              languageMode == "bilingual",
              pipelineProfile == "current_stt_only",
              validObservation,
              validCase
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let manifest = try Self.loadManifest(corpusRoot.appendingPathComponent("manifest.jsonl"))
        #expect(manifest.count == 42)
        guard manifest.count == 42 else { throw CocoaError(.fileReadCorruptFile) }
        let row = try #require(manifest.first { $0.id == sampleID })
        let reference = try Self.validatedReference(for: row)
        let adapter = PacedPCMAdapter()
        let transcriber = WhisperCppTranscriber(
            modelURL: modelURL,
            modelID: modelID
        )
        if temperature == "warm" {
            try await transcriber.prepare(language: nil)
        }

        let audioURL = corpusRoot
            .appendingPathComponent("audio_16k")
            .appendingPathComponent(row.audio)
        let audio = try Self.readWAV(audioURL)
        let totalStartedAt = ProcessInfo.processInfo.systemUptime
        let capture = try await adapter.capture(audio)
        let stopAt = ProcessInfo.processInfo.systemUptime
        let segments = adapter.segments(
            capture.audio,
            maximumDuration: maximumDuration
        )
        var isFirstDecode = temperature == "cold"
        var decodeDuration: TimeInterval = 0
        var transcriptParts: [String] = []
        var detectedLanguages: Set<String> = []
        var observedOutcome = "success"
        for (segmentIndex, segment) in segments.enumerated() {
            let segmentStartedAt = ProcessInfo.processInfo.systemUptime
            let result = await transcriber.transcribe(.init(
                audio: segment,
                allowedLanguages: ["ru", "en"],
                isFinalChunk: segmentIndex == segments.count - 1,
                decodeTimeout: isFirstDecode
                    ? TranscriptionDeadlinePolicy.coldDecodeSeconds
                    : TranscriptionDeadlinePolicy.warmDecodeSeconds
            ))
            decodeDuration += ProcessInfo.processInfo.systemUptime - segmentStartedAt
            isFirstDecode = false
            if !result.text.isEmpty { transcriptParts.append(result.text) }
            if !result.detectedLanguage.isEmpty {
                detectedLanguages.insert(result.detectedLanguage)
            }
            if result.outcome != .success, observedOutcome == "success" {
                observedOutcome = result.outcome.telemetryValue
            }
        }
        let completedAt = ProcessInfo.processInfo.systemUptime
        let hypothesis = Scoring.normalize(transcriptParts.joined(separator: " "))
        let termHits = try Scoring.termHitCount(hypothesis: hypothesis, terms: row.terms)
        try Self.append(OutputRow(
            caseID: caseID,
            modelID: modelID,
            modelChecksum: modelChecksum,
            corpusChecksum: corpusChecksum,
            sampleID: row.id,
            sampleCount: audio.count,
            language: row.lang,
            bucket: row.bucket,
            repetition: repetition,
            repetitions: repetitions,
            temperature: temperature,
            languageMode: languageMode,
            pipelineProfile: pipelineProfile,
            maxSpeechDuration: maximumDuration,
            captureDurationSeconds: capture.duration,
            decodeDurationSeconds: decodeDuration,
            stopToTextSeconds: completedAt - stopAt,
            totalDurationSeconds: completedAt - totalStartedAt,
            outcome: observedOutcome,
            detectedLanguage: detectedLanguages.sorted().joined(separator: ","),
            wordErrors: Scoring.editDistance(reference, hypothesis),
            referenceWordCount: reference.count,
            termHits: termHits,
            termTotal: row.terms.count
        ), to: outputURL)
        await transcriber.stop()
    }

    private static func loadManifest(_ url: URL) throws -> [ManifestRow] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(ManifestRow.self, from: Data($0.utf8)) }
    }

    private static func validatedReference(for row: ManifestRow) throws -> [String] {
        guard ["short", "medium", "long"].contains(row.bucket) else {
            throw ManifestContractError.unsupportedBucket
        }
        let reference = Scoring.normalize(row.text)
        guard !reference.isEmpty else { throw ManifestContractError.emptyReference }
        return reference
    }

    private static func append(_ row: OutputRow, to url: URL) throws {
        var data = try JSONEncoder().encode(row)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        func uint32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        guard data.count >= 12,
              String(bytes: data[0 ..< 4], encoding: .ascii) == "RIFF",
              String(bytes: data[8 ..< 12], encoding: .ascii) == "WAVE"
        else { throw CocoaError(.fileReadCorruptFile) }
        var position = 12
        var dataStart = -1
        var dataSize = 0
        while position + 8 <= data.count {
            let id = String(bytes: data[position ..< position + 4], encoding: .ascii) ?? ""
            let size = uint32(position + 4)
            guard position + 8 + size <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            if id == "data" {
                dataStart = position + 8
                dataSize = size
                break
            }
            position += 8 + size + (size & 1)
        }
        guard dataStart >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        var output: [Float] = []
        output.reserveCapacity(dataSize / 2)
        var index = dataStart
        while index + 1 < dataStart + dataSize {
            let sample = Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
            output.append(Float(sample) / 32_768)
            index += 2
        }
        return output
    }
}
