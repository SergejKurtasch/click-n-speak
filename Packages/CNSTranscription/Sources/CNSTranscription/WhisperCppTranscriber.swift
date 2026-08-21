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
    public enum LoadError: Error, Sendable { case modelNotFound(String), initFailed }

    /// `_PRE_WARM_THROTTLE_S` in the Python app.
    static let preWarmThrottleSeconds: TimeInterval = 45

    private let modelURL: URL
    private let threadCount: Int32
    private var warmupDone = false
    private var lastDecodeAt: Date?
    /// Owns the whisper_context so a nonisolated deinit can free it (the pointer
    /// is non-Sendable and the model holds ~GBs, so leaking on dealloc is not OK).
    private let contextBox = WhisperContextBox()
    /// Read by whisper.cpp's abort callback on the decoding thread, written by
    /// `abortInFlight()` from wherever the watchdog runs.
    private let abortFlag = AbortFlag()

    public init(modelURL: URL, threadCount: Int = 0) {
        self.modelURL = modelURL
        let cpus = ProcessInfo.processInfo.activeProcessorCount
        self.threadCount = Int32(threadCount > 0 ? threadCount : min(8, cpus))
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
        guard let created = modelURL.path.withCString({ whisper_init_from_file_with_params(($0), cparams) }) else {
            throw LoadError.initFailed
        }
        contextBox.ptr = created
        return created
    }

    public func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        guard !request.audio.isEmpty, let ctx = try? load() else { return .empty }

        var params = makeParams()

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
        return retry.text.isEmpty ? .empty : retry
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
        params.entropy_thold = 2.0       // ≈ compression_ratio_threshold
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
        abortFlag.value = true
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

        abortFlag.value = false
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue().value
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()

        return withOptionalCString(language) { langPtr in
            withOptionalCString(prompt) { promptPtr in
                params.language = langPtr
                params.initial_prompt = promptPtr
                let status = audio.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
                guard status == 0 else { return TranscriptionResult.empty }

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
                return TranscriptionResult(text: text, detectedLanguage: detected)
            }
        }
    }

    /// One-time warm decode of silence to load the model + compile Metal shaders
    /// (`WhisperTranscriber.warmup`). Idempotent.
    public func warmup(language: String?) async {
        guard !warmupDone else { return }
        warmupDone = true
        decodeSilence(seconds: 0.5, language: language)
    }

    /// Cheap keep-warm before a session. Skipped when a real decode happened
    /// less than 45 s ago, matching the Python `pre_warm` throttle that
    /// eliminated the 15-22 s cold-start penalty on rapid re-recordings.
    public func preWarm() async {
        if let last = lastDecodeAt, Date().timeIntervalSince(last) < Self.preWarmThrottleSeconds {
            return
        }
        decodeSilence(seconds: 0.5, language: nil)
    }

    private func decodeSilence(seconds: Double, language: String?) {
        guard let ctx = try? load() else { return }
        var params = makeParams()
        let silence = [Float](repeating: 0, count: Int(16000 * seconds))
        _ = runDecode(ctx: ctx, audio: silence, params: &params, language: language, prompt: nil)
        lastDecodeAt = Date()
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

/// Abort switch polled by whisper.cpp during a decode.
/// @unchecked Sendable: a single Bool, written by the watchdog and read by the
/// decoding thread; a torn read is impossible and a late read only costs one
/// more decode step.
final class AbortFlag: @unchecked Sendable {
    var value: Bool = false
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
