#if CNS_MODEL_TESTS
import CNSCore
import Darwin
import Foundation
import Testing
@testable import CNSTranscription

private struct GoldenThresholds: Decodable {
    let source: String
    let initialPrompt: String
    let benchmarkUserTerms: [String: [String]]
    let maximumOverallWER: Double
    let maximumRussianWER: Double
    let maximumEnglishWER: Double
    let maximumCodeSwitchWER: Double
    let minimumShortCommandAccuracy: Double
    let minimumTermRecall: Double
    let maximumWarmP50Seconds: Double
    let maximumWarmP95Seconds: Double
    let maximumColdP50Seconds: Double
    let maximumColdP95Seconds: Double
    let maximumPeakRSSMB: Double
    let coldSampleIDs: [String]

    enum CodingKeys: String, CodingKey {
        case source
        case initialPrompt = "initial_prompt"
        case benchmarkUserTerms = "benchmark_user_terms"
        case maximumOverallWER = "maximum_overall_wer"
        case maximumRussianWER = "maximum_russian_wer"
        case maximumEnglishWER = "maximum_english_wer"
        case maximumCodeSwitchWER = "maximum_code_switch_wer"
        case minimumShortCommandAccuracy = "minimum_short_command_accuracy"
        case minimumTermRecall = "minimum_term_recall"
        case maximumWarmP50Seconds = "maximum_warm_p50_seconds"
        case maximumWarmP95Seconds = "maximum_warm_p95_seconds"
        case maximumColdP50Seconds = "maximum_cold_p50_seconds"
        case maximumColdP95Seconds = "maximum_cold_p95_seconds"
        case maximumPeakRSSMB = "maximum_peak_rss_mb"
        case coldSampleIDs = "cold_sample_ids"
    }
}

private struct GoldenRow: Decodable, Sendable {
    let id: String
    let lang: String
    let bucket: String
    let text: String
    let terms: [String]
    let audio: String
}

private struct WERAccumulator {
    var errors = 0
    var words = 0
    var value: Double { Double(errors) / Double(max(1, words)) }

    mutating func add(reference: [String], hypothesis: [String]) {
        errors += GoldenScoring.editDistance(reference, hypothesis)
        words += reference.count
    }
}

private enum GoldenScoring {
    private static let numberWords: [String: Int] = [
        "один": 1, "одна": 1, "одного": 1, "два": 2, "две": 2, "двух": 2,
        "три": 3, "трех": 3, "четыре": 4, "четырех": 4, "пять": 5, "пяти": 5,
        "шесть": 6, "шести": 6, "семь": 7, "семи": 7, "восемь": 8, "восьми": 8,
        "девять": 9, "девяти": 9, "десять": 10, "десяти": 10,
        "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50,
        "сто": 100, "двести": 200, "триста": 300, "четыреста": 400, "пятьсот": 500,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "twenty": 20, "thirty": 30, "fifty": 50, "hundred": 100
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
        var previous = Array(0...hypothesis.count)
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

    static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
        return sorted[index]
    }
}

@Suite("WhisperCpp real-model golden parity", .serialized)
struct WhisperCppTranscriberTests {
    @Test("A Russian-primary bilingual profile preserves each spoken language")
    func bilingualSpokenLanguages() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelPath = try #require(environment["CNS_WHISPER_MODEL"])
        let modelID = try #require(environment["CNS_WHISPER_MODEL_ID"])
        let corpusRoot = environment["CNS_STT_GOLDEN_DIR"].map(URL.init(fileURLWithPath:))
            ?? Self.repositoryRoot.appendingPathComponent("spikes/stt-bakeoff/golden")
        let manifest = try Self.loadManifest(
            corpusRoot.appendingPathComponent("manifest.jsonl")
        )
        let englishRow = try #require(manifest.first { $0.id == "040" })
        let russianRow = try #require(manifest.first { $0.id == "001" })
        let audioRoot = corpusRoot.appendingPathComponent("audio_16k")
        let englishAudio = try Self.readWAV(audioRoot.appendingPathComponent(englishRow.audio))
        let russianAudio = try Self.readWAV(audioRoot.appendingPathComponent(russianRow.audio))
        let modelURL = URL(fileURLWithPath: modelPath)
        try Self.validateModelIdentity(modelURL, modelID: modelID)
        let engine = WhisperCppTranscriber(
            modelURL: modelURL,
            modelID: modelID
        )
        let prompts = [
            "ru": "Русский язык. Это разговорная речь.",
            "en": "English language. This is spoken language with professional and technical vocabulary."
        ]
        let english = await engine.transcribe(.init(
            audio: englishAudio,
            initialPrompt: "Расставляй знаки препинания. Пиши с заглавной буквы. Русский язык. English language. Это разговорная речь.",
            initialPromptsByLanguage: prompts,
            allowedLanguages: ["ru", "en"],
            isFinalChunk: true
        ))
        let russian = await engine.transcribe(.init(
            audio: russianAudio,
            initialPrompt: "Расставляй знаки препинания. Пиши с заглавной буквы. Русский язык. English language. Это разговорная речь.",
            initialPromptsByLanguage: prompts,
            allowedLanguages: ["ru", "en"],
            isFinalChunk: true
        ))
        await engine.stop()

        #expect(english.outcome == .success)
        #expect(english.detectedLanguage == "en")
        #expect(english.text.lowercased().contains("please review"))
        #expect(russian.outcome == .success)
        #expect(russian.detectedLanguage == "ru")
        #expect(russian.text.contains("Останови"))
    }

    @Test("42-phrase corpus meets declared quality, latency, and RSS thresholds")
    func goldenCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelPath = try #require(environment["CNS_WHISPER_MODEL"])
        let modelID = try #require(environment["CNS_WHISPER_MODEL_ID"])
        let modelURL = URL(fileURLWithPath: modelPath)
        try Self.validateModelIdentity(modelURL, modelID: modelID)
        let corpusRoot = environment["CNS_STT_GOLDEN_DIR"].map(URL.init(fileURLWithPath:))
            ?? Self.repositoryRoot.appendingPathComponent("spikes/stt-bakeoff/golden")
        let thresholds = try Self.loadThresholds()
        let rows = try Self.loadManifest(corpusRoot.appendingPathComponent("manifest.jsonl"))
        #expect(rows.count == 42)

        let engine = WhisperCppTranscriber(
            modelURL: modelURL,
            modelID: modelID
        )
        let guarded = GuardedTranscriber(wrapping: engine)
        let context = await ChunkContextBuilder().build(
            instruction: "",
            vocabPrompt: thresholds.initialPrompt,
            transcribedParts: [],
            tokenCount: { text in await engine.tokenCount(text) }
        )
        await engine.reload()

        var overall = WERAccumulator()
        var groups: [String: WERAccumulator] = [:]
        var warmDurations: [Double] = []
        var coldDurations: [Double] = []
        var termHits = 0
        var termTotal = 0
        var missedTerms: [String] = []
        var peakRSS = Self.peakRSSMB()

        for (index, row) in rows.enumerated() {
            let audioURL = corpusRoot.appendingPathComponent("audio_16k").appendingPathComponent(row.audio)
            let audio = try Self.readWAV(audioURL)
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = await guarded.transcribe(TranscriptionRequest(
                audio: audio,
                initialPrompt: context,
                // The recorded acceptance baseline forced the manifest's
                // primary language. Multilingual auto-detection remains
                // covered separately by request-contract tests.
                allowedLanguages: row.lang == "en" ? ["en"] : ["ru"],
                isFinalChunk: true,
                decodeTimeout: index == 0
                    ? TranscriptionDeadlinePolicy.coldDecodeSeconds
                    : TranscriptionDeadlinePolicy.warmDecodeSeconds
            ))
            let duration = ProcessInfo.processInfo.systemUptime - startedAt
            #expect(result.outcome == .success)
            let reference = GoldenScoring.normalize(row.text)
            let hypothesis = GoldenScoring.normalize(result.text)
            overall.add(reference: reference, hypothesis: hypothesis)
            groups[row.lang, default: WERAccumulator()].add(reference: reference, hypothesis: hypothesis)
            groups["bucket:\(row.bucket)", default: WERAccumulator()].add(
                reference: reference,
                hypothesis: hypothesis
            )
            if index == 0 { coldDurations.append(duration) } else { warmDurations.append(duration) }
            let hypothesisText = hypothesis.joined(separator: " ")
            for term in row.terms {
                termTotal += 1
                if hypothesisText.contains(GoldenScoring.normalize(term).joined(separator: " ")) {
                    termHits += 1
                } else {
                    missedTerms.append("\(row.id):\(term)")
                }
            }
            peakRSS = max(peakRSS, Self.peakRSSMB())
        }

        for id in thresholds.coldSampleIDs.dropFirst() {
            let row = try #require(rows.first { $0.id == id })
            await engine.reload()
            let audio = try Self.readWAV(
                corpusRoot.appendingPathComponent("audio_16k").appendingPathComponent(row.audio)
            )
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = await guarded.transcribe(.init(
                audio: audio,
                initialPrompt: context,
                allowedLanguages: row.lang == "en" ? ["en"] : ["ru"],
                isFinalChunk: true,
                decodeTimeout: TranscriptionDeadlinePolicy.coldDecodeSeconds
            ))
            coldDurations.append(ProcessInfo.processInfo.systemUptime - startedAt)
            #expect(result.outcome == .success)
            peakRSS = max(peakRSS, Self.peakRSSMB())
        }
        await engine.stop()

        let russianWER = groups["ru"]?.value ?? .infinity
        let englishWER = groups["en"]?.value ?? .infinity
        let codeSwitchWER = groups["ru+en"]?.value ?? .infinity
        let shortAccuracy = 1 - (groups["bucket:short"]?.value ?? 1)
        let termRecall = Double(termHits) / Double(max(1, termTotal))
        let warmP50 = GoldenScoring.percentile(warmDurations, 0.50)
        let warmP95 = GoldenScoring.percentile(warmDurations, 0.95)
        let coldP50 = GoldenScoring.percentile(coldDurations, 0.50)
        let coldP95 = GoldenScoring.percentile(coldDurations, 0.95)

        print("Golden source: \(thresholds.source)")
        print("Golden missed terms: \(missedTerms.joined(separator: ", "))")
        print(String(
            format: "Golden metrics: WER %.3f ru %.3f en %.3f code %.3f short-accuracy %.3f term-recall %.3f warm p50/p95 %.2f/%.2f cold p50/p95 %.2f/%.2f peak RSS %.0f MB",
            overall.value, russianWER, englishWER, codeSwitchWER, shortAccuracy,
            termRecall, warmP50, warmP95, coldP50, coldP95, peakRSS
        ))

        #expect(overall.value <= thresholds.maximumOverallWER)
        #expect(russianWER <= thresholds.maximumRussianWER)
        #expect(englishWER <= thresholds.maximumEnglishWER)
        #expect(codeSwitchWER <= thresholds.maximumCodeSwitchWER)
        #expect(shortAccuracy >= thresholds.minimumShortCommandAccuracy)
        #expect(termRecall >= thresholds.minimumTermRecall)
        #expect(warmP50 <= thresholds.maximumWarmP50Seconds)
        #expect(warmP95 <= thresholds.maximumWarmP95Seconds)
        #expect(coldP50 <= thresholds.maximumColdP50Seconds)
        #expect(coldP95 <= thresholds.maximumColdP95Seconds)
        #expect(peakRSS <= thresholds.maximumPeakRSSMB)
    }

    @Test("Bilingual session request meets the corpus quality gates")
    func bilingualSessionRequestCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CNS_RUN_BILINGUAL_SESSION_PROMPT_MODEL_TESTS"] == "1" else { return }
        let modelPath = try #require(environment["CNS_WHISPER_MODEL"])
        let modelID = try #require(environment["CNS_WHISPER_MODEL_ID"])
        let modelURL = URL(fileURLWithPath: modelPath)
        try Self.validateModelIdentity(modelURL, modelID: modelID)
        let corpusRoot = environment["CNS_STT_GOLDEN_DIR"].map(URL.init(fileURLWithPath:))
            ?? Self.repositoryRoot.appendingPathComponent("spikes/stt-bakeoff/golden")
        let thresholds = try Self.loadThresholds()
        let rows = try Self.loadManifest(corpusRoot.appendingPathComponent("manifest.jsonl"))
        let config = Self.benchmarkConfig(thresholds: thresholds)
        let engine = WhisperCppTranscriber(modelURL: modelURL, modelID: modelID)
        let context = await ChunkContextBuilder().build(
            instruction: "",
            vocabPrompt: thresholds.initialPrompt,
            transcribedParts: [],
            tokenCount: { text in await engine.tokenCount(text) }
        )
        let languagePrompts = await Self.languagePrompts(config: config, engine: engine)
        let guarded = GuardedTranscriber(wrapping: engine)
        var overall = WERAccumulator()
        var warmDurations: [Double] = []

        for (index, row) in rows.enumerated() {
            let audio = try Self.readWAV(
                corpusRoot.appendingPathComponent("audio_16k").appendingPathComponent(row.audio)
            )
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = await guarded.transcribe(TranscriptionRequest(
                audio: audio,
                initialPrompt: context,
                initialPromptsByLanguage: languagePrompts,
                allowedLanguages: ["ru", "en"],
                isFinalChunk: true
            ))
            #expect(result.outcome == .success)
            overall.add(
                reference: GoldenScoring.normalize(row.text),
                hypothesis: GoldenScoring.normalize(result.text)
            )
            if index > 0 {
                warmDurations.append(ProcessInfo.processInfo.systemUptime - startedAt)
            }
        }
        await engine.stop()

        let warmP50 = GoldenScoring.percentile(warmDurations, 0.50)
        print(String(
            format: "Bilingual session-request WER %.3f warm p50 %.2f",
            overall.value,
            warmP50
        ))
        #expect(overall.value <= thresholds.maximumOverallWER)
        #expect(warmP50 <= thresholds.maximumWarmP50Seconds)
    }

    private static func benchmarkConfig(thresholds: GoldenThresholds) -> Config {
        var raw = JSONObject()
        raw["schema_version"] = .int(10)
        raw["primary_language"] = .string("ru")
        raw["additional_languages"] = .array([.string("en")])
        raw["language_auto_detect"] = .bool(false)
        raw["initial_prompt"] = .string(thresholds.initialPrompt)
        var userTerms = JSONObject()
        for (language, terms) in thresholds.benchmarkUserTerms {
            userTerms[language] = .array(terms.map(JSONValue.string))
        }
        raw["user_terms"] = .object(userTerms)
        return Config(raw: raw)
    }

    private static func languagePrompts(
        config: Config,
        engine: WhisperCppTranscriber
    ) async -> [String: String] {
        let builder = InitialPromptBuilder()
        var prompts: [String: String] = [:]
        for language in ["ru", "en"] {
            var raw = config.raw
            raw["primary_language"] = .string(language)
            raw["additional_languages"] = .array([])
            let prompt = await ChunkContextBuilder().build(
                instruction: "",
                vocabPrompt: builder.build(config: raw),
                transcribedParts: [],
                tokenCount: { text in await engine.tokenCount(text) }
            )
            if !prompt.isEmpty { prompts[language] = prompt }
        }
        return prompts
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func loadThresholds() throws -> GoldenThresholds {
        let url = try #require(
            Bundle.module.url(
                forResource: "golden_thresholds",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(GoldenThresholds.self, from: Data(contentsOf: url))
    }

    private static func loadManifest(_ url: URL) throws -> [GoldenRow] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(GoldenRow.self, from: Data($0.utf8)) }
    }

    private static func validateModelIdentity(_ modelURL: URL, modelID: String) throws {
        guard let model = ModelRegistry.whisperModel(id: modelID) else { return }
        #expect(modelURL.lastPathComponent == model.fileName)
        guard modelURL.lastPathComponent == model.fileName else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    private static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        func uint32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        var position = 12
        var dataStart = -1
        var dataSize = 0
        while position + 8 <= data.count {
            let id = String(bytes: data[position..<(position + 4)], encoding: .ascii) ?? ""
            let size = uint32(position + 4)
            if id == "data" {
                dataStart = position + 8
                dataSize = min(size, data.count - dataStart)
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

    private static func peakRSSMB() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_maxrss) / (1_024 * 1_024)
    }
}
#endif
