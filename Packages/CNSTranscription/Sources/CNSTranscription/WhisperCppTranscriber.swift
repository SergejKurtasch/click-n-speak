import CNSCore
import Foundation
import whisper

/// Local STT via whisper.cpp (Metal), the engine selected in the Phase 0
/// bake-off. An `actor` so the blocking `whisper_full` decode is serialized and
/// the `whisper_context` is never touched concurrently — this is the Swift
/// equivalent of the single-threaded transcriber child process in the Python
/// app, without the multiprocessing machinery.
///
/// Decode parameters mirror production (`transcriber.py` realtime path): greedy,
/// temperature 0, strict no-speech/compression thresholds. Audio guards and the
/// hallucination filter are applied by `GuardedTranscriber` wrapping this, so
/// the engine adapter stays focused on decoding.
public actor WhisperCppTranscriber: Transcribing {
    public enum LoadError: Error, Sendable { case modelNotFound(String), initFailed, inferenceBusy }

    /// `_PRE_WARM_THROTTLE_S` in the Python app.
    static let preWarmThrottleSeconds: TimeInterval = 45

    private let modelURL: URL
    private let modelID: String
    private let threadCount: Int32
    private let inferenceGate: InferenceExecutionGate?
    private var warmupDone = false
    private var lastDecodeAt: Date?
    /// Owns the whisper_context so a nonisolated deinit can free it (the pointer
    /// is non-Sendable and the model holds ~GBs, so leaking on dealloc is not OK).
    private let contextBox = WhisperContextBox()
    /// Read by whisper.cpp's abort callback on the decoding thread, written by
    /// `abortInFlight()` from wherever the watchdog runs.
    private let abortFlag = AbortFlag()

    public init(
        modelURL: URL,
        modelID: String? = nil,
        threadCount: Int = 0,
        inferenceGate: InferenceExecutionGate? = nil
    ) {
        self.modelURL = modelURL
        self.modelID = modelID ?? modelURL.deletingPathExtension().lastPathComponent
        self.inferenceGate = inferenceGate
        let cpus = ProcessInfo.processInfo.activeProcessorCount
        // Four threads is the fastest stable configuration for the in-process
        // Metal build on Apple Silicon; using efficiency cores increases both
        // median latency and its tail.
        self.threadCount = Int32(threadCount > 0 ? threadCount : min(4, cpus))
    }

    /// Load the model (idempotent). Called lazily on first transcribe and by warmup.
    @discardableResult
    private func load() throws -> OpaquePointer {
        if let ctx = contextBox.ptr { return ctx }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LoadError.modelNotFound(modelURL.path)
        }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true  // Metal
        cparams.flash_attn = true
        guard let created = modelURL.path.withCString({
            whisper_init_from_file_with_params($0, cparams)
        }) else {
            throw LoadError.initFailed
        }
        contextBox.ptr = created
        return created
    }

    public func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        guard !request.audio.isEmpty else { return .guarded(.emptyAudio) }
        let inferenceLease: InferenceExecutionLease?
        if let inferenceGate {
            do {
                inferenceLease = try await inferenceGate.acquire(
                    timeout: request.decodeTimeout ?? TranscriptionDeadlinePolicy.coldDecodeSeconds
                )
            } catch {
                return TranscriptionResult(text: "", outcome: .aborted)
            }
            guard inferenceLease != nil else {
                return TranscriptionResult(text: "", outcome: .timedOut)
            }
        } else {
            inferenceLease = nil
        }
        defer { inferenceLease?.release() }
        let ctx: OpaquePointer
        do {
            ctx = try load()
        } catch {
            return .failed(.init(kind: .modelLoad, message: "The local speech model could not be loaded"))
        }

        var params = makeParams()
        // Each app chunk is an independent whisper_full invocation. Session
        // context is already supplied explicitly through initial_prompt by
        // ChunkContextBuilder; retaining whisper.cpp's prior-call tokens here
        // contaminates later sessions and duplicates that bounded context.
        params.no_context = true

        // Force the language only when exactly one is allowed (matches the
        // Python rule); otherwise auto-detect.
        let language: String? = request.allowedLanguages.count == 1 ? request.allowedLanguages[0] : nil

        let result = runDecode(ctx: ctx, audio: request.audio, params: &params,
                               language: language, prompt: request.initialPrompt)
        lastDecodeAt = Date()

        guard let retried = languageRetryIfNeeded(ctx: ctx, request: request, result: result) else {
            return result
        }
        return retried
    }

    public func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        progress(.init(stage: .preparing))
        let reader: MediaAudioSegmentReader
        do {
            reader = try await MediaAudioSegmentReader.open(url: request.url)
        } catch is CancellationError {
            return FileTranscriptionResult(text: "", status: .cancelled)
        } catch MediaAudioDecoderError.unsupportedMedia {
            return .failed(.init(kind: .unsupportedMedia, message: "This media type is not supported"))
        } catch {
            return .failed(.init(kind: .fileDecode, message: "The audio track could not be decoded"))
        }

        var parts: [String] = []
        var detectedLanguage = ""
        var segmentIndex = 0
        do {
            progress(.init(
                stage: .decoding,
                completedUnits: 0,
                totalUnits: reader.estimatedSegmentCount
            ))
            var current = try reader.nextSegment()
            while let audio = current {
                try Task.checkCancellation()
                let next = try reader.nextSegment()
                progress(.init(
                    stage: .transcribing,
                    completedUnits: segmentIndex,
                    totalUnits: reader.estimatedSegmentCount
                ))
                let result = await GuardedTranscriber(wrapping: self).transcribe(TranscriptionRequest(
                    audio: audio,
                    initialPrompt: request.initialPrompt,
                    allowedLanguages: request.allowedLanguages,
                    conditionOnPreviousText: true,
                    isFinalChunk: next == nil,
                    decodeTimeout: segmentIndex == 0
                        ? TranscriptionDeadlinePolicy.coldDecodeSeconds
                        : TranscriptionDeadlinePolicy.warmDecodeSeconds
                ))
                switch result.outcome {
                case .success:
                    let cleaned = HallucinationFilter().filter(result.text, isFinal: next == nil)
                    if !cleaned.isEmpty { parts.append(cleaned) }
                    if !result.detectedLanguage.isEmpty { detectedLanguage = result.detectedLanguage }
                case .noSpeech, .guarded:
                    break
                case .aborted:
                    reader.cancel()
                    return FileTranscriptionResult(text: "", status: .cancelled, segmentCount: segmentIndex)
                case .timedOut:
                    reader.cancel()
                    return .failed(.init(kind: .decode, message: "Local transcription timed out"))
                case let .failed(failure):
                    reader.cancel()
                    return .failed(failure)
                }
                segmentIndex += 1
                current = next
            }
        } catch is CancellationError {
            abortInFlight()
            reader.cancel()
            return FileTranscriptionResult(text: "", status: .cancelled, segmentCount: segmentIndex)
        } catch {
            reader.cancel()
            return .failed(.init(kind: .fileDecode, message: "The media file could not be decoded"))
        }

        let text = FileTranscriptAssembler.join(parts)
        progress(.init(stage: .completed, completedUnits: segmentIndex, totalUnits: segmentIndex))
        return FileTranscriptionResult(
            text: text,
            detectedLanguage: detectedLanguage,
            backend: "local",
            modelID: modelID,
            status: text.isEmpty ? .noSpeech : .success,
            segmentCount: segmentIndex
        )
    }

    /// Language-mismatch retry, ported from `WhisperTranscriber.transcribe`.
    /// When a non-final, non-trivial chunk decodes into a language outside the
    /// allowed set, pad it with 0.1 s of silence on both ends to shift the
    /// decoding window and try once more. The retry text is kept regardless of
    /// its language (losing the chunk is worse); only an empty retry drops it.
    /// Returns nil when no retry applies.
    private func languageRetryIfNeeded(
        ctx: OpaquePointer, request: TranscriptionRequest, result: TranscriptionResult
    ) -> TranscriptionResult? {
        guard !request.isFinalChunk, !request.allowedLanguages.isEmpty, !result.text.isEmpty else { return nil }

        let words = result.text.split(whereSeparator: { $0.isWhitespace })
        let isTrivial = words.count <= 1 || !words.contains(where: { $0.contains(where: { $0.isLetter || $0.isNumber }) })
        guard !isTrivial else { return nil }

        let detected = result.detectedLanguage.lowercased()
        guard !detected.isEmpty else { return nil }
        let allowed = request.allowedLanguages.map { $0.lowercased() }
        let isAllowed = allowed.contains(detected)
            || allowed.contains { $0.contains(detected) || detected.contains($0) }
        guard !isAllowed else { return nil }

        let pad = [Float](repeating: 0, count: 1600) // 0.1 s at 16 kHz
        let padded = pad + request.audio + pad
        var params = makeParams()
        let language: String? = request.allowedLanguages.count == 1 ? request.allowedLanguages[0] : nil
        let retry = runDecode(ctx: ctx, audio: padded, params: &params,
                              language: language, prompt: request.initialPrompt)
        guard !retry.text.isEmpty else { return retry }
        var retried = retry
        retried.retryCount = result.retryCount + 1
        retried.durationSeconds += result.durationSeconds
        return retried
    }

    private func makeParams() -> whisper_full_params {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threadCount
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.single_segment = false
        params.temperature = 0.0
        params.no_speech_thold = 0.5     // production strict
        // whisper.cpp's entropy metric is only analogous to OpenAI's
        // compression ratio. 2.4 is the accepted greedy bake-off setting;
        // using Python's numeric 2.0 here triggers expensive fallback decodes.
        params.entropy_thold = 2.4
        params.suppress_blank = true
        return params
    }

    /// Exact BPE token count from the model's own tokenizer, for the 220-token
    /// prompt budget in `ChunkContextBuilder` (replaces the len/3 heuristic).
    public func tokenCount(_ text: String) async -> Int? {
        guard let ctx = try? load() else { return nil }
        let n = text.withCString { whisper_token_count(ctx, $0) }
        return n >= 0 ? Int(n) : nil
    }

    /// Ask the decode that is currently running to give up.
    ///
    /// The Python app achieves this by restarting the transcriber child process,
    /// whose generation bump releases the blocked caller. In-process there is no
    /// process to kill, so we use whisper.cpp's own abort callback: it is polled
    /// between encoder/decoder steps and makes `whisper_full` return early.
    /// Callable from any isolation — the flag is the only thing touched.
    public nonisolated func abortInFlight() {
        abortFlag.abortActiveGeneration()
    }

    /// Nested withCString calls keep the language/prompt C strings alive across
    /// the whisper_full call.
    private func runDecode(
        ctx: OpaquePointer, audio: [Float],
        params: inout whisper_full_params, language: String?, prompt: String?
    ) -> TranscriptionResult {
        func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
            if let s { return s.withCString { body($0) } }
            return body(nil)
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let abortToken = abortFlag.beginGeneration()
        defer { abortFlag.endGeneration(abortToken.generation) }
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<AbortToken>.fromOpaque(userData).takeUnretainedValue().isAborted
                || Task.isCancelled
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abortToken).toOpaque()

        return withOptionalCString(language) { langPtr in
            withOptionalCString(prompt) { promptPtr in
                params.language = langPtr
                params.initial_prompt = promptPtr
                let status = audio.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
                let duration = ProcessInfo.processInfo.systemUptime - startedAt
                guard status == 0 else {
                    if abortToken.isAborted || Task.isCancelled {
                        return TranscriptionResult(
                            text: "",
                            outcome: .aborted,
                            backend: "local",
                            modelID: modelID,
                            durationSeconds: duration
                        )
                    }
                    return TranscriptionResult(
                        text: "",
                        outcome: .failed(.init(kind: .decode, message: "Local speech decoding failed")),
                        backend: "local",
                        modelID: modelID,
                        durationSeconds: duration
                    )
                }

                var text = ""
                let n = whisper_full_n_segments(ctx)
                for i in 0..<n {
                    if let seg = whisper_full_get_segment_text(ctx, i) {
                        text += String(cString: seg)
                    }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)

                var detected = ""
                let langId = whisper_full_lang_id(ctx)
                if langId >= 0, let langStr = whisper_lang_str(langId) {
                    detected = String(cString: langStr)
                }
                return TranscriptionResult(
                    text: text,
                    detectedLanguage: detected,
                    outcome: text.isEmpty ? .noSpeech : .success,
                    backend: "local",
                    modelID: modelID,
                    durationSeconds: duration
                )
            }
        }
    }

    /// One-time warm decode of silence to load the model + compile Metal shaders
    /// (`WhisperTranscriber.warmup`). Idempotent.
    public func warmup(language: String?) async {
        guard !warmupDone else { return }
        if let inferenceGate {
            guard let lease = try? await inferenceGate.acquire(
                timeout: TranscriptionDeadlinePolicy.coldDecodeSeconds
            ) else { return }
            defer { lease.release() }
            warmupDone = decodeSilence(seconds: 0.5, language: language)
        } else {
            warmupDone = decodeSilence(seconds: 0.5, language: language)
        }
    }

    public func prepare(language: String?) async throws {
        if let inferenceGate {
            guard let lease = try await inferenceGate.acquire(
                timeout: TranscriptionDeadlinePolicy.coldDecodeSeconds
            ) else { throw LoadError.inferenceBusy }
            defer { lease.release() }
            _ = try load()
            if !warmupDone { warmupDone = decodeSilence(seconds: 0.5, language: language) }
        } else {
            _ = try load()
            if !warmupDone { warmupDone = decodeSilence(seconds: 0.5, language: language) }
        }
    }

    /// Cheap keep-warm before a session. Skipped when a real decode happened
    /// less than 45 s ago, matching the Python `pre_warm` throttle that
    /// eliminated the 15-22 s cold-start penalty on rapid re-recordings.
    public func preWarm() async -> PrewarmResult {
        if let last = lastDecodeAt, Date().timeIntervalSince(last) < Self.preWarmThrottleSeconds {
            return .warmed
        }
        guard let lease = inferenceGate?.tryAcquire() else {
            return inferenceGate == nil
                ? (decodeSilence(seconds: 0.5, language: nil) ? .warmed : .failed)
                : .skipped
        }
        defer { lease.release() }
        return decodeSilence(seconds: 0.5, language: nil) ? .warmed : .failed
    }

    private func decodeSilence(seconds: Double, language: String?) -> Bool {
        guard let ctx = try? load() else { return false }
        var params = makeParams()
        let silence = [Float](repeating: 0, count: Int(16000 * seconds))
        _ = runDecode(ctx: ctx, audio: silence, params: &params, language: language, prompt: nil)
        lastDecodeAt = Date()
        return true
    }

    public func stop() async {
        contextBox.free()
    }

    /// Drop the model so the next decode reloads it from scratch — the in-process
    /// equivalent of the Python periodic transcriber restart, which exists to
    /// release model weight tensors that a cache clear cannot free.
    public func reload() async {
        contextBox.free()
        warmupDone = false
    }
}

/// Generation-scoped abort state shared by the actor and whisper.cpp callback.
/// A watchdog can only mark the generation that is active at that instant; a
/// late abort therefore cannot leak into the next decode.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration = 0
    private var activeGeneration: Int?
    private var abortedGeneration: Int?

    func beginGeneration() -> AbortToken {
        lock.lock()
        nextGeneration += 1
        let generation = nextGeneration
        activeGeneration = generation
        abortedGeneration = nil
        lock.unlock()
        return AbortToken(owner: self, generation: generation)
    }

    func abortActiveGeneration() {
        lock.lock()
        abortedGeneration = activeGeneration
        lock.unlock()
    }

    func isAborted(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation && abortedGeneration == generation
    }

    func endGeneration(_ generation: Int) {
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = nil
            abortedGeneration = nil
        }
        lock.unlock()
    }
}

final class AbortToken: @unchecked Sendable {
    let generation: Int
    private let owner: AbortFlag

    init(owner: AbortFlag, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    var isAborted: Bool { owner.isAborted(generation) }
}

/// Holds the whisper_context pointer outside the actor so a nonisolated deinit
/// can release it. @unchecked Sendable: the pointer is only mutated by the
/// owning actor's serialized methods; no concurrent access by contract.
private final class WhisperContextBox: @unchecked Sendable {
    var ptr: OpaquePointer?

    func free() {
        if let ptr {
            whisper_free(ptr)
            self.ptr = nil
        }
    }

    deinit { free() }
}
