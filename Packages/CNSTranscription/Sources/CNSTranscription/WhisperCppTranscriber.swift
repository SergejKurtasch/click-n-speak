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

    private let modelURL: URL
    private let threadCount: Int32
    /// Owns the whisper_context so a nonisolated deinit can free it (the pointer
    /// is non-Sendable and the model holds ~GBs, so leaking on dealloc is not OK).
    private let contextBox = WhisperContextBox()

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

        // Force the language only when exactly one is allowed (matches the
        // Python rule); otherwise auto-detect.
        let language: String? = request.allowedLanguages.count == 1 ? request.allowedLanguages[0] : nil

        return runDecode(ctx: ctx, audio: request.audio, params: &params,
                         language: language, prompt: request.initialPrompt)
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

    /// One-time warm decode of silence to load the model + compile Metal shaders.
    public func warmup(language: String?) async {
        guard let ctx = try? load() else { return }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threadCount
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        let silence = [Float](repeating: 0, count: 16000 / 2) // 0.5 s
        _ = silence.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
    }

    public func stop() async {
        contextBox.free()
    }
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
