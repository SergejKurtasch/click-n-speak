import Foundation

private enum GuardedDecodeEvent: Sendable {
    case result(TranscriptionResult)
    case timeout
}

/// Wraps any `Transcribing` engine with the engine-independent pre-decode audio
/// guards and post-decode hallucination filtering from `transcriber.py`. Keeps
/// those concerns out of each engine adapter so local and cloud backends share
/// identical filtering behaviour.
public struct GuardedTranscriber: Transcribing {
    private let inner: any Transcribing
    private let filter: HallucinationFilter

    public init(wrapping inner: any Transcribing, filter: HallucinationFilter = HallucinationFilter()) {
        self.inner = inner
        self.filter = filter
    }

    public func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        // Pre-decode guards: skip silence / tiny chunks before hitting the engine.
        if let reason = AudioGuards.skipReason(
            sampleCount: request.audio.count, samples: request.audio, isFinal: request.isFinalChunk
        ) {
            switch reason {
            case .tinyFinalChunk: return .guarded(.tinyFinalChunk)
            case .silentShortChunk: return .guarded(.silentShortChunk)
            }
        }

        let result: TranscriptionResult
        if let timeout = request.decodeTimeout, timeout > 0 {
            result = await decode(request, timeout: timeout)
        } else {
            result = await inner.transcribe(request)
        }
        guard !result.text.isEmpty else { return result }

        let cleaned = filter.filter(result.text, isFinal: request.isFinalChunk)
        guard !cleaned.isEmpty else {
            var guarded = result
            guarded.text = ""
            guarded.outcome = .guarded(.hallucination)
            return guarded
        }
        var cleanedResult = result
        cleanedResult.text = cleaned
        cleanedResult.outcome = .success
        return cleanedResult
    }

    private func decode(
        _ request: TranscriptionRequest,
        timeout: TimeInterval
    ) async -> TranscriptionResult {
        let operation = Task { [inner] in
            GuardedDecodeEvent.result(await inner.transcribe(request))
        }
        let stream = AsyncStream<GuardedDecodeEvent> { continuation in
            let waiter = Task {
                continuation.yield(await operation.value)
                continuation.finish()
            }
            let timer = Task { [inner] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    return
                }
                inner.abortInFlight()
                continuation.yield(.timeout)
                continuation.finish()
                operation.cancel()
            }
            continuation.onTermination = { _ in
                waiter.cancel()
                timer.cancel()
            }
        }

        let first = await withTaskCancellationHandler {
            await stream.first(where: { _ in true })
        } onCancel: {
            inner.abortInFlight()
            operation.cancel()
        }
        switch first {
        case let .result(result):
            return result
        case .timeout:
            return TranscriptionResult(text: "", outcome: .timedOut, durationSeconds: timeout)
        case nil:
            if Task.isCancelled {
                return TranscriptionResult(text: "", outcome: .aborted)
            }
            return TranscriptionResult(text: "", outcome: .timedOut, durationSeconds: timeout)
        }
    }

    public func warmup(language: String?) async { await inner.warmup(language: language) }
    public func prepare(language: String?) async throws { try await inner.prepare(language: language) }
    public func preWarm() async { await inner.preWarm() }
    public func stop() async { await inner.stop() }
    public func reload() async { await inner.reload() }
    public nonisolated func abortInFlight() { inner.abortInFlight() }
    public func tokenCount(_ text: String) async -> Int? { await inner.tokenCount(text) }

    public func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        var result = await inner.transcribeFile(request, progress: progress)
        guard case .success = result.status else { return result }
        let cleaned = filter.filter(result.text, isFinal: true)
        if cleaned.isEmpty {
            result.text = ""
            result.status = .noSpeech
        } else {
            result.text = cleaned
        }
        return result
    }
}
