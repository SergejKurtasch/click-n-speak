import Foundation

/// Production cloud STT adapter shared by realtime and file workflows.
/// Request bodies, credentials, prompts, audio, and transcripts are never logged.
public actor CloudSTTTranscriber: Transcribing {
    public let backend: CloudSTTBackend
    public let modelName: String

    private struct ProviderPayload: Sendable {
        let text: String
        let detectedLanguage: String
    }

    private enum AttemptError: Error {
        case timedOut
        case aborted
        case failure(TranscriptionFailure, retryable: Bool)
    }

    private enum PayloadResponse: Sendable {
        case success(ProviderPayload, retryCount: Int)
        case failure(TranscriptionOutcome)
    }

    private let apiKey: String
    private let realtimeClient: any HTTPDataClient
    private let fileClient: any HTTPDataClient
    private let realtimeTimeouts: CloudSTTTimeouts
    private let fileTimeouts: CloudSTTTimeouts
    private let retryPolicy: CloudRetryPolicy
    private let maxInlineFileBytes: Int
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let inFlight = CloudInFlightRegistry()

    public init(
        backend: CloudSTTBackend,
        modelName: String,
        apiKey: String,
        realtimeClient: (any HTTPDataClient)? = nil,
        fileClient: (any HTTPDataClient)? = nil,
        realtimeTimeouts: CloudSTTTimeouts = .realtime,
        fileTimeouts: CloudSTTTimeouts = .file,
        retryPolicy: CloudRetryPolicy = .init(),
        maxInlineFileBytes: Int = 12 * 1_024 * 1_024,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.backend = backend
        self.modelName = modelName
        self.apiKey = apiKey
        self.realtimeTimeouts = realtimeTimeouts
        self.fileTimeouts = fileTimeouts
        self.realtimeClient = realtimeClient ?? realtimeTimeouts.makeClient()
        self.fileClient = fileClient ?? fileTimeouts.makeClient()
        self.retryPolicy = retryPolicy
        self.maxInlineFileBytes = max(1, maxInlineFileBytes)
        self.sleep = sleep
        self.jitter = jitter
    }

    public func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        guard !request.audio.isEmpty else { return .guarded(.emptyAudio) }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let response = await requestPayload(
            data: Self.makeWAVData(from: request.audio),
            mediaType: .wav,
            filename: "audio.wav",
            prompt: request.initialPrompt,
            allowedLanguages: request.allowedLanguages,
            client: realtimeClient,
            timeout: request.decodeTimeout ?? realtimeTimeouts.request
        )
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        switch response {
        case let .success(payload, retryCount):
            return TranscriptionResult(
                text: payload.text,
                detectedLanguage: payload.detectedLanguage,
                outcome: payload.text.isEmpty ? .noSpeech : .success,
                backend: backend.rawValue,
                modelID: modelName,
                retryCount: retryCount,
                durationSeconds: duration
            )
        case let .failure(outcome):
            return TranscriptionResult(
                text: "",
                outcome: outcome,
                backend: backend.rawValue,
                modelID: modelName,
                durationSeconds: duration
            )
        }
    }

    public func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        progress(.init(stage: .preparing))
        guard !Task.isCancelled else { return cancelledFileResult() }

        let mediaType: FileMediaType
        do {
            let handle = try FileHandle(forReadingFrom: request.url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 64) ?? Data()
            guard let detected = FileMediaType.detect(url: request.url, header: header) else {
                return .failed(.init(kind: .unsupportedMedia, message: "This media type is not supported"))
            }
            guard MediaFormatCapabilities.policy(for: detected) != .unsupported else {
                return .failed(.init(kind: .unsupportedMedia, message: "This media type is not supported"))
            }
            mediaType = detected
        } catch {
            return .failed(.init(kind: .fileDecode, message: "The media file could not be read"))
        }

        let size = (try? request.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        let isVideo = [.mp4, .mov, .m4v].contains(mediaType)
        if !isVideo,
           MediaFormatCapabilities.supportsDirectProviderUpload(mediaType),
           size <= maxInlineFileBytes {
            return await transcribeInlineFile(request, mediaType: mediaType, progress: progress)
        }
        return await transcribeSegmentedFile(request, progress: progress)
    }

    public nonisolated func abortInFlight() {
        inFlight.cancelCurrent()
    }

    private func transcribeInlineFile(
        _ request: FileTranscriptionRequest,
        mediaType: FileMediaType,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        do {
            try Task.checkCancellation()
            let data = try Data(contentsOf: request.url, options: .mappedIfSafe)
            progress(.init(stage: .uploading, completedUnits: 0, totalUnits: 1))
            let response = await requestPayload(
                data: data,
                mediaType: mediaType,
                filename: request.url.lastPathComponent,
                prompt: request.initialPrompt,
                allowedLanguages: request.allowedLanguages,
                client: fileClient,
                timeout: fileTimeouts.request
            )
            progress(.init(stage: .uploading, completedUnits: 1, totalUnits: 1))
            return fileResult(from: response, segmentCount: 1, progress: progress)
        } catch is CancellationError {
            return cancelledFileResult()
        } catch {
            return .failed(.init(kind: .fileDecode, message: "The media file could not be read"))
        }
    }

    private func transcribeSegmentedFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        let reader: MediaAudioSegmentReader
        do {
            reader = try await MediaAudioSegmentReader.open(url: request.url)
        } catch is CancellationError {
            return cancelledFileResult()
        } catch MediaAudioDecoderError.unsupportedMedia {
            return .failed(.init(kind: .unsupportedMedia, message: "This media type is not supported"))
        } catch {
            return .failed(.init(kind: .fileDecode, message: "The audio track could not be decoded"))
        }

        var transcript = FileTranscriptAccumulator(backend: backend.rawValue, modelID: modelName)
        var index = 0
        do {
            progress(.init(stage: .decoding, totalUnits: reader.estimatedSegmentCount))
            while let samples = try reader.nextSegment() {
                try Task.checkCancellation()
                progress(.init(stage: .uploading, completedUnits: index, totalUnits: reader.estimatedSegmentCount))
                let response = await requestPayload(
                    data: Self.makeWAVData(from: samples),
                    mediaType: .wav,
                    filename: "segment-\(index + 1).wav",
                    prompt: request.initialPrompt,
                    allowedLanguages: request.allowedLanguages,
                    client: fileClient,
                    timeout: fileTimeouts.request
                )
                switch response {
                case let .success(payload, _):
                    transcript.append(text: payload.text, detectedLanguage: payload.detectedLanguage)
                case .failure(.aborted):
                    reader.cancel()
                    return transcript.result(status: .cancelled, segmentCount: index)
                case .failure(.timedOut):
                    reader.cancel()
                    return transcript.result(
                        status: .failed(.init(kind: .network, message: "Cloud file transcription timed out")),
                        segmentCount: index
                    )
                case let .failure(.failed(failure)):
                    reader.cancel()
                    return transcript.result(status: .failed(failure), segmentCount: index)
                case let .failure(other):
                    reader.cancel()
                    return transcript.result(
                        status: .failed(.init(
                            kind: .unknown,
                            message: "Cloud file transcription failed: \(other.telemetryValue)"
                        )),
                        segmentCount: index
                    )
                }
                index += 1
                progress(.init(stage: .transcribing, completedUnits: index, totalUnits: reader.estimatedSegmentCount))
            }
        } catch is CancellationError {
            abortInFlight()
            reader.cancel()
            return transcript.result(status: .cancelled, segmentCount: index)
        } catch {
            reader.cancel()
            return transcript.result(
                status: .failed(.init(kind: .fileDecode, message: "The media file could not be decoded")),
                segmentCount: index
            )
        }

        progress(.init(stage: .completed, completedUnits: index, totalUnits: index))
        return transcript.completed(segmentCount: index)
    }

    private func requestPayload(
        data: Data,
        mediaType: FileMediaType,
        filename: String,
        prompt: String?,
        allowedLanguages: [String],
        client: any HTTPDataClient,
        timeout: TimeInterval
    ) async -> PayloadResponse {
        let preparedRequest: URLRequest
        do {
            preparedRequest = try makeRequest(
                data: data,
                mediaType: mediaType,
                filename: filename,
                prompt: prompt,
                allowedLanguages: allowedLanguages,
                timeout: timeout
            )
        } catch let error as AttemptError {
            switch error {
            case .aborted: return .failure(.aborted)
            case .timedOut: return .failure(.timedOut)
            case let .failure(failure, _): return .failure(.failed(failure))
            }
        } catch {
            return .failure(.failed(.init(kind: .invalidRequest, message: "Cloud request could not be created")))
        }

        var lastError: AttemptError = .failure(
            .init(kind: .unknown, message: "Cloud transcription failed"),
            retryable: false
        )
        for attempt in 1...retryPolicy.maxAttempts {
            if Task.isCancelled { return .failure(.aborted) }
            do {
                let payload = try await performCancellable {
                    let response = try await client.data(for: preparedRequest)
                    return try self.parse(response)
                }
                return .success(payload, retryCount: attempt - 1)
            } catch is CancellationError {
                return .failure(.aborted)
            } catch let error as AttemptError {
                lastError = error
                guard isRetryable(error), attempt < retryPolicy.maxAttempts else { break }
            } catch let error as URLError {
                if error.code == .cancelled { return .failure(.aborted) }
                lastError = error.code == .timedOut
                    ? .timedOut
                    : .failure(
                        .init(kind: .network, message: "The cloud speech service is unreachable"),
                        retryable: isTransient(error.code)
                    )
                guard isRetryable(lastError), attempt < retryPolicy.maxAttempts else { break }
            } catch {
                lastError = .failure(
                    .init(kind: .unknown, message: "Cloud transcription failed"),
                    retryable: false
                )
                break
            }

            let seconds = retryPolicy.delay(after: attempt, jitter: jitter())
            do {
                try await sleep(UInt64(seconds * 1_000_000_000))
            } catch {
                return .failure(.aborted)
            }
        }

        switch lastError {
        case .aborted:
            return .failure(.aborted)
        case .timedOut:
            return .failure(.timedOut)
        case let .failure(failure, retryable):
            if retryable, retryPolicy.maxAttempts > 1 {
                return .failure(.failed(.init(
                    kind: .retryExhausted,
                    message: "The cloud speech service did not recover after retrying",
                    statusCode: failure.statusCode
                )))
            }
            return .failure(.failed(failure))
        }
    }

    private func performCancellable<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let generation = inFlight.begin()
        let task = Task { try await operation() }
        inFlight.install(generation: generation) { task.cancel() }
        defer { inFlight.finish(generation: generation) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated func makeRequest(
        data: Data,
        mediaType: FileMediaType,
        filename: String,
        prompt: String?,
        allowedLanguages: [String],
        timeout: TimeInterval
    ) throws -> URLRequest {
        switch backend {
        case .gemini:
            return try makeGeminiRequest(
                data: data,
                mimeType: mediaType.mimeType,
                prompt: prompt,
                allowedLanguages: allowedLanguages,
                timeout: timeout
            )
        case .openai:
            return makeOpenAIRequest(
                data: data,
                mimeType: mediaType.mimeType,
                filename: filename,
                prompt: prompt,
                allowedLanguages: allowedLanguages,
                timeout: timeout
            )
        }
    }

    private nonisolated func makeGeminiRequest(
        data: Data,
        mimeType: String,
        prompt: String?,
        allowedLanguages: [String],
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw AttemptError.failure(
                .init(kind: .invalidRequest, message: "The cloud model identifier is invalid"),
                retryable: false
            )
        }
        var instruction = "Transcribe this audio. Return only the transcript without formatting or commentary."
        if allowedLanguages.count == 1 {
            instruction += " The spoken language is expected to be \(allowedLanguages[0])."
        } else if !allowedLanguages.isEmpty {
            instruction += " Expected languages may include: \(allowedLanguages.joined(separator: ", "))."
        }
        if let prompt, !prompt.isEmpty {
            instruction += " Preserve this vocabulary and context when appropriate: \(prompt)"
        }
        let body: [String: Any] = [
            "contents": [["parts": [
                ["inlineData": ["mimeType": mimeType, "data": data.base64EncodedString()]],
                ["text": instruction]
            ]]]
        ]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private nonisolated func makeOpenAIRequest(
        data: Data,
        mimeType: String,
        filename: String,
        prompt: String?,
        allowedLanguages: [String],
        timeout: TimeInterval
    ) -> URLRequest {
        let boundary = "cns-\(UUID().uuidString)"
        var body = Data()
        Self.appendMultipartField(name: "model", value: modelName, boundary: boundary, to: &body)
        if let prompt, !prompt.isEmpty {
            Self.appendMultipartField(name: "prompt", value: prompt, boundary: boundary, to: &body)
        }
        if allowedLanguages.count == 1 {
            Self.appendMultipartField(name: "language", value: allowedLanguages[0], boundary: boundary, to: &body)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.safeFilename(filename))\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private nonisolated func parse(_ response: HTTPDataResponse) throws -> ProviderPayload {
        guard (200..<300).contains(response.statusCode) else {
            let kind: TranscriptionFailureKind
            switch response.statusCode {
            case 400: kind = .invalidRequest
            case 401, 403: kind = .unauthorized
            case 429: kind = .rateLimited
            case 500...599: kind = .server
            default: kind = .network
            }
            let message = Self.boundedProviderMessage(response.data)
                ?? "The cloud speech service returned HTTP \(response.statusCode)"
            let retryable = response.statusCode == 429 || [500, 502, 503, 504].contains(response.statusCode)
            throw AttemptError.failure(
                .init(kind: kind, message: message, statusCode: response.statusCode),
                retryable: retryable
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw AttemptError.failure(
                .init(kind: .malformedResponse, message: "The cloud speech service returned an invalid response"),
                retryable: false
            )
        }
        let text: String?
        let language: String?
        switch backend {
        case .openai:
            text = object["text"] as? String
            language = object["language"] as? String
        case .gemini:
            let candidates = object["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            text = parts?.compactMap { $0["text"] as? String }.joined()
            language = nil
        }
        guard let text else {
            throw AttemptError.failure(
                .init(kind: .malformedResponse, message: "The cloud speech service response has no transcript"),
                retryable: false
            )
        }
        return ProviderPayload(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: language ?? ""
        )
    }

    private func fileResult(
        from response: PayloadResponse,
        segmentCount: Int,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) -> FileTranscriptionResult {
        switch response {
        case let .success(payload, _):
            progress(.init(stage: .completed, completedUnits: 1, totalUnits: 1))
            return FileTranscriptionResult(
                text: payload.text,
                detectedLanguage: payload.detectedLanguage,
                backend: backend.rawValue,
                modelID: modelName,
                status: payload.text.isEmpty ? .noSpeech : .success,
                segmentCount: segmentCount
            )
        case let .failure(.failed(failure)):
            return .failed(failure)
        case .failure(.aborted):
            return cancelledFileResult(segmentCount: segmentCount)
        case .failure(.timedOut):
            return .failed(.init(kind: .network, message: "Cloud file transcription timed out"))
        case let .failure(other):
            return .failed(.init(kind: .unknown, message: "Cloud file transcription failed: \(other.telemetryValue)"))
        }
    }

    private func cancelledFileResult(segmentCount: Int = 0) -> FileTranscriptionResult {
        FileTranscriptionResult(
            text: "",
            backend: backend.rawValue,
            modelID: modelName,
            status: .cancelled,
            segmentCount: segmentCount
        )
    }

    private func isRetryable(_ error: AttemptError) -> Bool {
        switch error {
        case .timedOut: true
        case .aborted: false
        case let .failure(_, retryable): retryable
        }
    }

    private func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            true
        default:
            false
        }
    }

    private static func appendMultipartField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    private static func safeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\"\r\n")
        return value.components(separatedBy: forbidden).joined(separator: "_")
    }

    private static func boundedProviderMessage(_ data: Data) -> String? {
        let prefix = Data(data.prefix(4_096))
        if let object = try? JSONSerialization.jsonObject(with: prefix) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return sanitize(message)
            }
            if let message = object["message"] as? String { return sanitize(message) }
        }
        return nil
    }

    private static func sanitize(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ").prefix(512))
    }

    static func makeWAVData(from floats: [Float]) -> Data {
        let clamped = floats.map { sample -> Int16 in
            let value = max(-1, min(1, sample))
            return Int16(value * Float(Int16.max))
        }
        let dataSize = UInt32(clamped.count * MemoryLayout<Int16>.size)
        var wav = Data(capacity: 44 + Int(dataSize))
        wav.append(Data("RIFF".utf8))
        appendLittleEndian(dataSize + 36, to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt32(16_000), to: &wav)
        appendLittleEndian(UInt32(32_000), to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLittleEndian(dataSize, to: &wav)
        clamped.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

private final class CloudInFlightRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration = 0
    private var activeGeneration: Int?
    private var cancelAction: (@Sendable () -> Void)?

    func begin() -> Int {
        lock.withLock {
            nextGeneration += 1
            activeGeneration = nextGeneration
            cancelAction = nil
            return nextGeneration
        }
    }

    func install(generation: Int, cancel: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard activeGeneration == generation else { return true }
            cancelAction = cancel
            return false
        }
        if shouldCancel { cancel() }
    }

    func cancelCurrent() {
        let action = lock.withLock { cancelAction }
        action?()
    }

    func finish(generation: Int) {
        lock.withLock {
            if activeGeneration == generation {
                activeGeneration = nil
                cancelAction = nil
            }
        }
    }
}
