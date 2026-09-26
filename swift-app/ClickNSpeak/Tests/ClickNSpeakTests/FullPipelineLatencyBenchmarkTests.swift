import CNSAudio
import CNSCore
import CNSEditors
import CNSSession
import CNSTranscription
import Foundation
import Testing

private enum FullPipelineBenchmarkError: Error {
    case invalidEnvironment
    case invalidWAV
    case missingCaptureTiming
    case timedOut
}

private struct FullPipelineManifestRow: Decodable {
    let id: String
    let lang: String
    let bucket: String
    let text: String
    let terms: [String]
    let audio: String
}

private struct FullPipelineSchedule: Decodable {
    let schemaVersion: Int
    let observations: [FullPipelineScheduledObservation]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case observations
    }
}

private struct FullPipelineScheduledObservation: Decodable {
    let sampleID: String
    let repetition: Int
    let temperature: String

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id"
        case repetition
        case temperature
    }
}

private struct FullPipelineOutputRow: Encodable {
    let schemaVersion = 5
    let adapter = "audiochunker_vad_session"
    let caseID: String
    let modelID: String
    let modelChecksum: String
    let editorModelChecksum: String?
    let corpusChecksum: String
    let promptChecksum: String
    let sampleID: String
    let sampleCount: Int
    let emittedSampleCount: Int
    let transcribedSampleCount: Int
    let chunkCount: Int
    let chunkSampleCounts: [Int]
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
    let stopToPreviewSeconds: Double
    let stopToPopupSeconds: Double
    let totalDurationSeconds: Double
    let outcome: String
    let editorOutcome: String
    let editorDurationSeconds: Double?
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
        case editorModelChecksum = "editor_model_checksum"
        case corpusChecksum = "corpus_checksum"
        case promptChecksum = "prompt_checksum"
        case sampleID = "sample_id"
        case sampleCount = "sample_count"
        case emittedSampleCount = "emitted_sample_count"
        case transcribedSampleCount = "transcribed_sample_count"
        case chunkCount = "chunk_count"
        case chunkSampleCounts = "chunk_sample_counts"
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
        case stopToPreviewSeconds = "stop_to_preview_seconds"
        case stopToPopupSeconds = "stop_to_popup_seconds"
        case totalDurationSeconds = "total_duration_seconds"
        case outcome
        case editorOutcome = "editor_outcome"
        case editorDurationSeconds = "editor_duration_seconds"
        case detectedLanguage = "detected_language"
        case wordErrors = "word_errors"
        case referenceWordCount = "reference_word_count"
        case termHits = "term_hits"
        case termTotal = "term_total"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(adapter, forKey: .adapter)
        try container.encode(caseID, forKey: .caseID)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(modelChecksum, forKey: .modelChecksum)
        if let editorModelChecksum {
            try container.encode(editorModelChecksum, forKey: .editorModelChecksum)
        } else {
            try container.encodeNil(forKey: .editorModelChecksum)
        }
        try container.encode(corpusChecksum, forKey: .corpusChecksum)
        try container.encode(promptChecksum, forKey: .promptChecksum)
        try container.encode(sampleID, forKey: .sampleID)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(emittedSampleCount, forKey: .emittedSampleCount)
        try container.encode(transcribedSampleCount, forKey: .transcribedSampleCount)
        try container.encode(chunkCount, forKey: .chunkCount)
        try container.encode(chunkSampleCounts, forKey: .chunkSampleCounts)
        try container.encode(language, forKey: .language)
        try container.encode(bucket, forKey: .bucket)
        try container.encode(repetition, forKey: .repetition)
        try container.encode(repetitions, forKey: .repetitions)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(languageMode, forKey: .languageMode)
        try container.encode(pipelineProfile, forKey: .pipelineProfile)
        try container.encode(maxSpeechDuration, forKey: .maxSpeechDuration)
        try container.encode(captureDurationSeconds, forKey: .captureDurationSeconds)
        try container.encode(decodeDurationSeconds, forKey: .decodeDurationSeconds)
        try container.encode(stopToPreviewSeconds, forKey: .stopToPreviewSeconds)
        try container.encode(stopToPopupSeconds, forKey: .stopToPopupSeconds)
        try container.encode(totalDurationSeconds, forKey: .totalDurationSeconds)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(editorOutcome, forKey: .editorOutcome)
        if let editorDurationSeconds {
            try container.encode(editorDurationSeconds, forKey: .editorDurationSeconds)
        } else {
            try container.encodeNil(forKey: .editorDurationSeconds)
        }
        try container.encode(detectedLanguage, forKey: .detectedLanguage)
        try container.encode(wordErrors, forKey: .wordErrors)
        try container.encode(referenceWordCount, forKey: .referenceWordCount)
        try container.encode(termHits, forKey: .termHits)
        try container.encode(termTotal, forKey: .termTotal)
    }
}

private final class PacedChunkingRecorder: AudioCapturing, @unchecked Sendable {
    private let audio: [Float]
    private let configuration: ChunkingConfig
    private let detector: any VoiceActivityDetecting
    private let lock = NSLock()
    private var callbacks: AudioCallbacks?
    private var captureTask: Task<Void, Never>?
    private var recording = false
    private var didCapture = false
    private var pendingFinal: [Float]?
    private var emittedSamples = 0
    private var finalSamples = 0
    private var stopUptime: TimeInterval?

    init(
        audio: [Float],
        configuration: ChunkingConfig,
        detector: any VoiceActivityDetecting = FVADVoiceActivityDetector()
    ) {
        self.audio = audio
        self.configuration = configuration
        self.detector = detector
    }

    var isRecording: Bool { lock.withLock { recording } }
    var captureCompleted: Bool { lock.withLock { didCapture } }
    var stopRequestedUptime: TimeInterval? { lock.withLock { stopUptime } }
    var emittedSampleCount: Int { lock.withLock { emittedSamples } }
    var deliveredSampleCount: Int { lock.withLock { emittedSamples + finalSamples } }

    func start(callbacks: AudioCallbacks, settings: RecordingSettings) async throws {
        lock.withLock {
            self.callbacks = callbacks
            recording = true
            didCapture = false
            pendingFinal = nil
            emittedSamples = 0
            finalSamples = 0
            stopUptime = nil
        }
        captureTask = Task { [weak self] in await self?.paceAndChunk(callbacks: callbacks) }
    }

    func stop() async {
        let task = lock.withLock { captureTask }
        await task?.value
        let completion = lock.withLock { () -> (AudioCallbacks?, [Float]?) in
            recording = false
            captureTask = nil
            stopUptime = ProcessInfo.processInfo.systemUptime
            let value = (callbacks, pendingFinal)
            callbacks = nil
            pendingFinal = nil
            return value
        }
        completion.0?.onFinal(completion.1)
    }

    private func paceAndChunk(callbacks: AudioCallbacks) async {
        let sampleRate = configuration.sampleRate
        let frameSamples = 480
        let clock = ContinuousClock()
        let startedAt = clock.now
        var chunker = AudioChunker(config: configuration)
        var accumulated: [Float] = []
        accumulated.reserveCapacity(audio.count)
        var offset = 0
        while offset < audio.count, !Task.isCancelled {
            let end = min(audio.count, offset + frameSamples)
            let frame = Array(audio[offset ..< end])
            let elapsedNanoseconds = Int64(
                Double(end) / Double(sampleRate) * 1_000_000_000
            )
            do {
                try await clock.sleep(
                    until: startedAt.advanced(by: .nanoseconds(elapsedNanoseconds))
                )
            } catch is CancellationError {
                break
            } catch {
                break
            }
            chunker.beginBlock(samples: frame.count)
            chunker.voiceFrame(
                isSpeech: detector.isSpeech(frame),
                seconds: Double(frame.count) / Double(sampleRate)
            )
            accumulated.append(contentsOf: frame)
            switch chunker.endBlock() {
            case .emit:
                emit(accumulated, callbacks: callbacks)
                accumulated.removeAll(keepingCapacity: true)
            case .discard:
                accumulated.removeAll(keepingCapacity: true)
            case .continue:
                break
            }
            offset = end
        }
        let final = chunker.shouldKeepFinalChunk(sampleCount: accumulated.count) ? accumulated : nil
        lock.withLock {
            pendingFinal = final
            finalSamples = final?.count ?? 0
            didCapture = true
        }
    }

    private func emit(_ chunk: [Float], callbacks: AudioCallbacks) {
        guard !chunk.isEmpty else { return }
        lock.withLock { emittedSamples += chunk.count }
        callbacks.onChunk(chunk)
    }
}

@MainActor
private final class FullPipelinePanel: PopupPresenting {
    private(set) var isShowingInteractive = false
    private(set) var currentText = ""
    private(set) var previewText = ""
    private(set) var previewUptime: TimeInterval?
    private(set) var popupUptime: TimeInterval?
    private var onCancel: (() -> Void)?

    func show(title: String) {}
    func updateStatus(_ title: String) {}
    func updateText(_ text: String) {
        previewText = text
        previewUptime = ProcessInfo.processInfo.systemUptime
    }
    func appendText(_ text: String) { currentText += " " + text }
    func showPendingAppend(_ text: String, title: String) {}
    func clearPendingAppend() {}
    func setDecisionEnabled(_ enabled: Bool) {}
    func showIncompleteWarning(_ message: String) {}
    func hide(delay: TimeInterval) { isShowingInteractive = false }

    func showInteractive(
        text: String,
        title: String,
        toasts: DictionaryToasts,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onAddToDictionary: ((String) -> AddTermResult)?
    ) {
        currentText = text
        popupUptime = ProcessInfo.processInfo.systemUptime
        isShowingInteractive = true
        self.onCancel = onCancel
    }

    func cancel() {
        guard isShowingInteractive else { return }
        isShowingInteractive = false
        let callback = onCancel
        onCancel = nil
        callback?()
    }
}

@MainActor
private struct FullPipelineDelivery: TextDelivering {
    func deliver(_ text: String, to pid: pid_t?) async -> TextDeliveryOutcome { .delivered }
}

@MainActor
private struct FullPipelineFrontmost: FrontmostAppProviding {
    func frontmostPid() -> pid_t? { 4242 }
}

private actor ObservedBenchmarkTranscriber: Transcribing {
    nonisolated let inner: any Transcribing
    private var results: [TranscriptionResult] = []
    private var duration: TimeInterval = 0
    private var samples = 0
    private var chunkCount = 0
    private var chunkSampleCounts: [Int] = []

    init(inner: any Transcribing) { self.inner = inner }

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = await inner.transcribe(request)
        duration += ProcessInfo.processInfo.systemUptime - startedAt
        samples += request.audio.count
        chunkCount += 1
        chunkSampleCounts.append(request.audio.count)
        results.append(result)
        return result
    }

    func warmup(language: String?) async { await inner.warmup(language: language) }
    func prepare(language: String?) async throws { try await inner.prepare(language: language) }
    func preWarm() async -> PrewarmResult { await inner.preWarm() }
    func stop() async { await inner.stop() }
    func reload() async { await inner.reload() }
    nonisolated func abortInFlight() { inner.abortInFlight() }
    func tokenCount(_ text: String) async -> Int? { await inner.tokenCount(text) }
    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        await inner.transcribeFile(request, progress: progress)
    }

    func observation() -> (
        duration: TimeInterval,
        samples: Int,
        chunkCount: Int,
        chunkSampleCounts: [Int],
        outcome: String,
        languages: String
    ) {
        let outcome = results.first(where: { $0.outcome != .success })?.outcome.telemetryValue ?? "success"
        let languages = Set(results.map(\.detectedLanguage).filter { !$0.isEmpty }).sorted().joined(separator: ",")
        return (duration, samples, chunkCount, chunkSampleCounts, outcome, languages)
    }

    func reset() {
        results.removeAll(keepingCapacity: true)
        duration = 0
        samples = 0
        chunkCount = 0
        chunkSampleCounts.removeAll(keepingCapacity: true)
    }
}

private actor ObservedBenchmarkEditor: AiEditing {
    nonisolated let inner: any AiEditing
    nonisolated let descriptor: AiEditorDescriptor
    nonisolated let isReady: Bool
    private var latestStatus: RefineStatus = .skipped
    private var latestDuration: TimeInterval?

    init(inner: any AiEditing) {
        self.inner = inner
        self.descriptor = inner.descriptor
        self.isReady = inner.isReady
    }

    func prepare() async throws { try await inner.prepare() }
    func preWarm(languages: [String]?, force: Bool) async -> PrewarmResult {
        await inner.preWarm(languages: languages, force: force)
    }
    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = await inner.refine(
            text: text,
            languages: languages,
            knownTerms: knownTerms,
            misrecognitions: misrecognitions
        )
        latestStatus = result.status
        latestDuration = ProcessInfo.processInfo.systemUptime - startedAt
        return result
    }
    func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        await inner.refineFileText(
            text: text,
            languages: languages,
            knownTerms: knownTerms,
            misrecognitions: misrecognitions
        )
    }
    func stop() async { await inner.stop() }
    func observation() -> (status: String, duration: TimeInterval?) {
        (latestStatus.rawValue, latestDuration)
    }

    func reset() {
        latestStatus = .skipped
        latestDuration = nil
    }
}

@MainActor
@Suite("Full pipeline latency benchmark", .serialized)
struct FullPipelineLatencyBenchmarkTests {
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

    @Test("Corpus reader accepts only 16 kHz mono PCM16 WAV")
    func corpusReaderRequiresCanonicalWAV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-pipeline-latency-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        var wav = Self.pcm16WAV(samples: [0, Int16.max, Int16.min])
        try wav.write(to: url)
        #expect(try Self.readWAV(url).count == 3)

        wav[24] = 0
        try wav.write(to: url)
        #expect(throws: FullPipelineBenchmarkError.self) {
            try Self.readWAV(url)
        }
    }

    @Test("Batch schedule has one cold observation before persistent warm runs")
    func batchScheduleUsesOneColdObservation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-pipeline-schedule-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(
            """
            {"schema_version":1,"observations":[
              {"sample_id":"001","repetition":0,"temperature":"cold"},
              {"sample_id":"002","repetition":0,"temperature":"warm"},
              {"sample_id":"001","repetition":1,"temperature":"warm"}
            ]}
            """.utf8
        ).write(to: url)
        let schedule = try Self.loadSchedule(url)
        #expect(schedule.map(\.sampleID) == ["001", "002", "001"])
        #expect(schedule.map(\.temperature) == ["cold", "warm", "warm"])

        try Data(
            """
            {"schema_version":1,"observations":[
              {"sample_id":"001","repetition":0,"temperature":"warm"}
            ]}
            """.utf8
        ).write(to: url)
        #expect(throws: FullPipelineBenchmarkError.self) {
            try Self.loadSchedule(url)
        }
    }

    @Test("Benchmark output explicitly encodes nullable columns")
    func benchmarkOutputEncodesNullableColumns() throws {
        let row = FullPipelineOutputRow(
            caseID: "B",
            modelID: "whisper-large-v3",
            modelChecksum: "model",
            editorModelChecksum: nil,
            corpusChecksum: "corpus",
            promptChecksum: "prompt",
            sampleID: "001",
            sampleCount: 16_000,
            emittedSampleCount: 16_000,
            transcribedSampleCount: 16_000,
            chunkCount: 1,
            chunkSampleCounts: [16_000],
            language: "ru",
            bucket: "short",
            repetition: 0,
            repetitions: 3,
            temperature: "cold",
            languageMode: "bilingual",
            pipelineProfile: "full_pipeline_stt_only",
            maxSpeechDuration: 8,
            captureDurationSeconds: 1,
            decodeDurationSeconds: 1,
            stopToPreviewSeconds: 1,
            stopToPopupSeconds: 1,
            totalDurationSeconds: 2,
            outcome: "success",
            editorOutcome: "skipped",
            editorDurationSeconds: nil,
            detectedLanguage: "ru",
            wordErrors: 0,
            referenceWordCount: 1,
            termHits: 0,
            termTotal: 0
        )

        let encoded = try JSONEncoder().encode(row)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schema_version"] as? Int == 5)
        #expect(object["prompt_checksum"] as? String == "prompt")
        #expect(object["chunk_count"] as? Int == 1)
        #expect(object["chunk_sample_counts"] as? [Int] == [16_000])
        #expect(object["editor_model_checksum"] is NSNull)
        #expect(object["editor_duration_seconds"] is NSNull)
    }

    @Test("WER edit distance charges one deleted word once")
    func editDistanceCountsOneDeletionOnce() {
        #expect(Self.editDistance(["alpha", "beta"], ["alpha"]) == 1)
    }

    @Test("Benchmark dictionary requires nonempty Russian and English terms")
    func benchmarkDictionaryRequiresBilingualTerms() throws {
        let terms = try Self.loadBenchmarkTerms("{\"ru\":[\"Whisper\"],\"en\":[\"Whisper\"]}")
        #expect(terms["ru"]?.arrayValue?.compactMap(\.stringValue) == ["Whisper"])
        #expect(terms["en"]?.arrayValue?.compactMap(\.stringValue) == ["Whisper"])

        #expect(throws: FullPipelineBenchmarkError.self) {
            try Self.loadBenchmarkTerms("{\"ru\":[\"Whisper\"]}")
        }
    }

    @Test("Full-pipeline quality uses the interactive text after refinement")
    func qualityUsesFinalInteractiveText() {
        let panel = FullPipelinePanel()
        panel.updateText("raw preview")
        panel.showInteractive(
            text: "edited final text",
            title: "",
            toasts: DictionaryToasts(),
            onConfirm: { _ in },
            onCancel: {},
            onAddToDictionary: nil
        )

        #expect(Self.qualityTokens(from: panel) == ["edited", "final", "text"])
    }

    @Test("Opt-in AudioChunker/VAD/SessionController benchmark emits a persistent full-pipeline batch")
    func fullPipelineBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CNS_LATENCY_BENCHMARKS"] == "1" else { return }
        let modelPath = try #require(environment["CNS_WHISPER_MODEL"])
        let modelID = try #require(environment["CNS_WHISPER_MODEL_ID"])
        let corpusPath = try #require(environment["CNS_STT_GOLDEN_DIR"])
        let outputPath = try #require(environment["CNS_BENCHMARK_OUTPUT"])
        let initialPrompt = try #require(environment["CNS_BENCHMARK_INITIAL_PROMPT"])
        let benchmarkTermsJSON = try #require(environment["CNS_BENCHMARK_USER_TERMS_JSON"])
        let promptChecksum = try #require(environment["CNS_BENCHMARK_PROMPT_SHA256"])
        let caseID = try #require(environment["CNS_BENCHMARK_CASE_ID"])
        let languageMode = try #require(environment["CNS_BENCHMARK_LANGUAGE_MODE"])
        let profile = try #require(environment["CNS_BENCHMARK_PIPELINE_PROFILE"])
        let schedulePath = try #require(environment["CNS_BENCHMARK_SCHEDULE"])
        let repetitions = try #require(environment["CNS_BENCHMARK_REPETITIONS"].flatMap(Int.init))
        let maxSpeechDuration = try #require(
            environment["CNS_BENCHMARK_MAX_SPEECH_DURATION"].flatMap(Double.init)
        )
        let modelChecksum = try #require(environment["CNS_BENCHMARK_MODEL_SHA256"])
        let corpusChecksum = try #require(environment["CNS_BENCHMARK_CORPUS_SHA256"])
        let editorModelChecksum = environment["CNS_BENCHMARK_QWEN_SHA256"]
        guard ["B", "C", "D"].contains(caseID),
              languageMode == "bilingual",
              ["full_pipeline_stt_only", "full_pipeline_local_qwen"].contains(profile),
              repetitions > 0,
              maxSpeechDuration > 0,
              !initialPrompt.isEmpty,
              promptChecksum.count == 64
        else { throw FullPipelineBenchmarkError.invalidEnvironment }
        let benchmarkTerms = try Self.loadBenchmarkTerms(benchmarkTermsJSON)

        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let rows = try Self.loadManifest(corpusURL.appendingPathComponent("manifest.jsonl"))
        let schedule = try Self.loadSchedule(URL(fileURLWithPath: schedulePath))
        guard schedule.allSatisfy({ $0.repetition <= repetitions }) else {
            throw FullPipelineBenchmarkError.invalidEnvironment
        }

        let gate = InferenceExecutionGate()
        let localTranscriber = GuardedTranscriber(
            wrapping: WhisperCppTranscriber(
                modelURL: URL(fileURLWithPath: modelPath),
                modelID: modelID,
                inferenceGate: gate
            )
        )
        let transcriber = ObservedBenchmarkTranscriber(inner: localTranscriber)
        let editor: ObservedBenchmarkEditor?
        if profile == "full_pipeline_local_qwen" {
            let qwenPath = try #require(environment["CNS_QWEN_MODEL_DIR"])
            _ = try #require(editorModelChecksum)
            let localEditor = LocalAiEditor(
                modelID: "qwen2.5-1.5b-4bit",
                modelDirectory: URL(fileURLWithPath: qwenPath, isDirectory: true),
                gate: gate
            )
            try await localEditor.prepare()
            editor = ObservedBenchmarkEditor(inner: localEditor)
        } else {
            editor = nil
        }
        let chunking = ChunkingConfig(
            silenceDuration: 1,
            targetSpeechDuration: 4,
            maxSpeechDuration: maxSpeechDuration,
            minSpeechDuration: 1
        )
        var didPreWarm = false
        do {
            for scheduledObservation in schedule {
                if scheduledObservation.temperature == "warm", !didPreWarm {
                    #expect(await transcriber.preWarm() == .warmed)
                    if let editor {
                        #expect(await editor.preWarm(languages: ["ru", "en"], force: true) == .warmed)
                    }
                    didPreWarm = true
                }
                await transcriber.reset()
                if let editor { await editor.reset() }

                let row = try #require(rows.first { $0.id == scheduledObservation.sampleID })
                let reference = Self.normalize(row.text)
                guard !reference.isEmpty else { throw FullPipelineBenchmarkError.invalidEnvironment }
                let audio = try Self.readWAV(
                    corpusURL.appendingPathComponent("audio_16k").appendingPathComponent(row.audio)
                )
                let recorder = PacedChunkingRecorder(audio: audio, configuration: chunking)
                let panel = FullPipelinePanel()
                var raw = JSONObject()
                raw["schema_version"] = .int(10)
                raw["primary_language"] = .string("ru")
                raw["additional_languages"] = .array([.string("en")])
                raw["language_auto_detect"] = .bool(false)
                raw["initial_prompt"] = .string(initialPrompt)
                raw["user_terms"] = .object(benchmarkTerms)
                raw["ai_editor_enabled"] = .bool(editor != nil)
                raw["silence_duration"] = .double(1)
                raw["target_speech_duration"] = .double(4)
                raw["min_speech_duration"] = .double(1)
                raw["max_speech_duration"] = .double(maxSpeechDuration)
                let controller = SessionController(
                    config: Config(raw: raw),
                    transcriber: transcriber,
                    aiEditor: editor,
                    recorder: recorder,
                    panel: panel,
                    delivery: FullPipelineDelivery(),
                    frontmost: FullPipelineFrontmost()
                )

                let totalStartedAt = ProcessInfo.processInfo.systemUptime
                controller.toggle(now: Date())
                try await Self.waitUntil { recorder.captureCompleted }
                controller.toggle(now: Date().addingTimeInterval(1))
                try await Self.waitUntil { panel.isShowingInteractive }
                let completedAt = ProcessInfo.processInfo.systemUptime
                let stopAt = try #require(recorder.stopRequestedUptime)
                let previewAt = try #require(panel.previewUptime)
                let popupAt = try #require(panel.popupUptime)
                guard popupAt >= stopAt else {
                    throw FullPipelineBenchmarkError.missingCaptureTiming
                }
                let transcription = await transcriber.observation()
                let editorObservation = await editor?.observation() ?? ("skipped", nil)
                let hypothesis = Self.qualityTokens(from: panel)
                let termHits = Self.termHitCount(hypothesis: hypothesis, terms: row.terms)
                try Self.append(FullPipelineOutputRow(
                    caseID: caseID,
                    modelID: modelID,
                    modelChecksum: modelChecksum,
                    editorModelChecksum: profile == "full_pipeline_local_qwen" ? editorModelChecksum : nil,
                    corpusChecksum: corpusChecksum,
                    promptChecksum: promptChecksum,
                    sampleID: row.id,
                    sampleCount: audio.count,
                    emittedSampleCount: recorder.deliveredSampleCount,
                    transcribedSampleCount: transcription.samples,
                    chunkCount: transcription.chunkCount,
                    chunkSampleCounts: transcription.chunkSampleCounts,
                    language: row.lang,
                    bucket: row.bucket,
                    repetition: scheduledObservation.repetition,
                    repetitions: repetitions,
                    temperature: scheduledObservation.temperature,
                    languageMode: languageMode,
                    pipelineProfile: profile,
                    maxSpeechDuration: maxSpeechDuration,
                    captureDurationSeconds: Double(audio.count) / 16_000,
                    decodeDurationSeconds: transcription.duration,
                    stopToPreviewSeconds: max(0, previewAt - stopAt),
                    stopToPopupSeconds: popupAt - stopAt,
                    totalDurationSeconds: completedAt - totalStartedAt,
                    outcome: transcription.outcome,
                    editorOutcome: editorObservation.0,
                    editorDurationSeconds: editorObservation.1,
                    detectedLanguage: transcription.languages,
                    wordErrors: Self.editDistance(reference, hypothesis),
                    referenceWordCount: reference.count,
                    termHits: termHits,
                    termTotal: row.terms.count
                ), to: URL(fileURLWithPath: outputPath))
                panel.cancel()
                await controller.shutdown()
            }
        } catch {
            await transcriber.stop()
            if let editor { await editor.stop() }
            throw error
        }
        await transcriber.stop()
        if let editor { await editor.stop() }
    }

    private static func loadBenchmarkTerms(_ source: String) throws -> JSONObject {
        let data = Data(source.utf8)
        let payload: Any
        do {
            payload = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FullPipelineBenchmarkError.invalidEnvironment
        }
        guard let raw = payload as? [String: Any] else {
            throw FullPipelineBenchmarkError.invalidEnvironment
        }
        var terms = JSONObject()
        for language in ["ru", "en"] {
            guard let values = raw[language] as? [Any], !values.isEmpty else {
                throw FullPipelineBenchmarkError.invalidEnvironment
            }
            let strings = values.compactMap { $0 as? String }
            guard strings.count == values.count,
                  strings.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw FullPipelineBenchmarkError.invalidEnvironment }
            terms[language] = .array(strings.map(JSONValue.string))
        }
        return terms
    }

    private static func loadSchedule(_ url: URL) throws -> [FullPipelineScheduledObservation] {
        let schedule = try JSONDecoder().decode(FullPipelineSchedule.self, from: Data(contentsOf: url))
        let observations = schedule.observations
        guard schedule.schemaVersion == 1,
              let first = observations.first,
              first.temperature == "cold",
              first.repetition == 0,
              observations.dropFirst().allSatisfy({ $0.temperature == "warm" }),
              observations.allSatisfy({
                  !$0.sampleID.isEmpty && $0.repetition >= 0 && ["cold", "warm"].contains($0.temperature)
              }),
              Set(observations.map { "\($0.repetition):\($0.sampleID)" }).count == observations.count
        else { throw FullPipelineBenchmarkError.invalidEnvironment }
        return observations
    }

    private static func loadManifest(_ url: URL) throws -> [FullPipelineManifestRow] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(FullPipelineManifestRow.self, from: Data($0.utf8)) }
    }

    private static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44,
              data[0 ..< 4] == Data("RIFF".utf8),
              data[8 ..< 12] == Data("WAVE".utf8),
              try littleEndianUInt32(data, at: 4) == UInt32(data.count - 8)
        else { throw FullPipelineBenchmarkError.invalidWAV }
        var format: Data?
        var samples: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let identifier = data[offset ..< offset + 4]
            let byteCount = Int(try littleEndianUInt32(data, at: offset + 4))
            let contentOffset = offset + 8
            guard byteCount <= data.count - contentOffset else {
                throw FullPipelineBenchmarkError.invalidWAV
            }
            let contentEnd = contentOffset + byteCount
            let paddedEnd = contentEnd + (byteCount & 1)
            guard paddedEnd <= data.count else { throw FullPipelineBenchmarkError.invalidWAV }
            if identifier == Data("fmt ".utf8) {
                guard format == nil else { throw FullPipelineBenchmarkError.invalidWAV }
                format = Data(data[contentOffset ..< contentEnd])
            } else if identifier == Data("data".utf8) {
                guard samples == nil else { throw FullPipelineBenchmarkError.invalidWAV }
                samples = Data(data[contentOffset ..< contentEnd])
            }
            offset = paddedEnd
        }
        guard let format, let samples, format.count >= 16 else {
            throw FullPipelineBenchmarkError.invalidWAV
        }
        let formatTag = try littleEndianUInt16(format, at: 0)
        let isPCM: Bool
        if formatTag == 1 {
            isPCM = true
        } else if formatTag == 0xFFFE, format.count >= 40 {
            let pcmSubformat = Data([
                0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
            ])
            isPCM = try littleEndianUInt16(format, at: 16) >= 22
                && littleEndianUInt16(format, at: 18) == 16
                && Data(format[24 ..< 40]) == pcmSubformat
        } else {
            isPCM = false
        }
        guard isPCM,
              try littleEndianUInt16(format, at: 2) == 1,
              try littleEndianUInt32(format, at: 4) == 16_000,
              try littleEndianUInt32(format, at: 8) == 32_000,
              try littleEndianUInt16(format, at: 12) == 2,
              try littleEndianUInt16(format, at: 14) == 16,
              !samples.isEmpty,
              samples.count.isMultiple(of: 2)
        else { throw FullPipelineBenchmarkError.invalidWAV }
        return stride(from: 0, to: samples.count, by: 2).map { offset in
            let value = Int16(bitPattern: UInt16(samples[offset]) | UInt16(samples[offset + 1]) << 8)
            return Float(value) / Float(Int16.max)
        }
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, data.count - offset >= 2 else {
            throw FullPipelineBenchmarkError.invalidWAV
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, data.count - offset >= 4 else {
            throw FullPipelineBenchmarkError.invalidWAV
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func waitUntil(
        timeout: TimeInterval = 120,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw FullPipelineBenchmarkError.timedOut
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func pcm16WAV(samples: [Int16]) -> Data {
        let dataSize = samples.count * 2
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + dataSize), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(16_000), to: &data)
        appendLittleEndian(UInt32(32_000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(dataSize), to: &data)
        for sample in samples {
            appendLittleEndian(UInt16(bitPattern: sample), to: &data)
        }
        return data
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8(value >> 8))
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000FF))
        data.append(UInt8((value >> 8) & 0x000000FF))
        data.append(UInt8((value >> 16) & 0x000000FF))
        data.append(UInt8((value >> 24) & 0x000000FF))
    }

    private static func normalize(_ text: String) -> [String] {
        let tokens = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
        var normalized: [String] = []
        var index = 0
        while index < tokens.count {
            guard numberWords[tokens[index]] != nil else {
                normalized.append(tokens[index])
                index += 1
                continue
            }
            var total = 0
            while index < tokens.count, let value = numberWords[tokens[index]] {
                total += value
                index += 1
            }
            normalized.append(String(total))
        }
        return normalized
    }

    private static func qualityTokens(from panel: FullPipelinePanel) -> [String] {
        normalize(panel.currentText)
    }

    private static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
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

    private static func termHitCount(hypothesis: [String], terms: [String]) -> Int {
        terms.reduce(into: 0) { hits, term in
            let tokens = normalize(term)
            guard !tokens.isEmpty, tokens.count <= hypothesis.count else { return }
            if (0 ... hypothesis.count - tokens.count).contains(where: { start in
                hypothesis[start ..< start + tokens.count].elementsEqual(tokens)
            }) {
                hits += 1
            }
        }
    }

    private static func append(_ row: FullPipelineOutputRow, to url: URL) throws {
        var data = try JSONEncoder().encode(row)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
