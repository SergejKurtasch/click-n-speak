import Foundation
import XCTest
@testable import CNSTranscription

private actor ScriptedHTTPClient: HTTPDataClient {
    enum Step: Sendable {
        case response(Int, Data)
        case urlError(URLError.Code)
        case waitForCancellation
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func data(for request: URLRequest) async throws -> HTTPDataResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        switch step {
        case let .response(status, data):
            return HTTPDataResponse(statusCode: status, data: data)
        case let .urlError(code):
            throw URLError(code)
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.cancelled)
        }
    }

    var requestCount: Int { requests.count }
    func request(at index: Int) -> URLRequest { requests[index] }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileTranscriptionProgress] = []

    func append(_ value: FileTranscriptionProgress) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [FileTranscriptionProgress] { lock.withLock { values } }
}

final class CloudSTTTranscriberTests: XCTestCase {
    private let audio = [Float](repeating: 0.1, count: 16_000)
    private let noDelay: @Sendable (UInt64) async throws -> Void = { _ in }

    func testOpenAIAutoDetectOmitsLanguageAndUsesPrompt() async throws {
        let response = try json(["text": "hello"])
        let client = ScriptedHTTPClient([.response(200, response)])
        let transcriber = makeTranscriber(.openai, realtime: client)

        let result = await transcriber.transcribe(.init(
            audio: audio,
            initialPrompt: "Click-n-speak vocabulary",
            allowedLanguages: []
        ))

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.detectedLanguage, "")
        XCTAssertEqual(result.backend, "openai")
        XCTAssertEqual(result.modelID, "fixture-model")
        let capturedRequest = await client.request(at: 0)
        let body = capturedRequest.httpBody ?? Data()
        XCTAssertNotNil(body.range(of: Data("name=\"prompt\"".utf8)))
        XCTAssertNotNil(body.range(of: Data("Click-n-speak vocabulary".utf8)))
        XCTAssertNil(body.range(of: Data("name=\"language\"".utf8)))
    }

    func testOpenAISingleLanguageUsesProviderFieldAndReportedLanguageOnly() async throws {
        let response = try json(["text": "привет", "language": "ru"])
        let client = ScriptedHTTPClient([.response(200, response)])
        let transcriber = makeTranscriber(.openai, realtime: client)

        let result = await transcriber.transcribe(.init(audio: audio, allowedLanguages: ["ru"]))

        XCTAssertEqual(result.detectedLanguage, "ru")
        let capturedRequest = await client.request(at: 0)
        let body = capturedRequest.httpBody ?? Data()
        XCTAssertNotNil(body.range(of: Data("name=\"language\"".utf8)))
        XCTAssertNotNil(body.range(of: Data("\r\nru\r\n".utf8)))
    }

    func testGeminiPayloadCarriesMIMEPromptAndLanguageHint() async throws {
        let response = try json([
            "candidates": [["content": ["parts": [["text": "bonjour"]]]]]
        ])
        let client = ScriptedHTTPClient([.response(200, response)])
        let transcriber = makeTranscriber(.gemini, realtime: client)

        let result = await transcriber.transcribe(.init(
            audio: audio,
            initialPrompt: "NomPropre",
            allowedLanguages: ["fr"]
        ))

        XCTAssertEqual(result.text, "bonjour")
        XCTAssertEqual(result.detectedLanguage, "")
        let request = await client.request(at: 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        )
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(parts.first?["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/wav")
        let instruction = try XCTUnwrap(parts.last?["text"] as? String)
        XCTAssertTrue(instruction.contains("fr"))
        XCTAssertTrue(instruction.contains("NomPropre"))
    }

    func testClientErrorsAreTypedAndNotRetried() async throws {
        for (status, expected): (Int, TranscriptionFailureKind) in [
            (400, .invalidRequest),
            (401, .unauthorized)
        ] {
            let body = try json(["error": ["message": "provider rejected request"]])
            let client = ScriptedHTTPClient([.response(status, body)])
            let transcriber = makeTranscriber(.openai, realtime: client)
            let result = await transcriber.transcribe(.init(audio: audio))
            guard case let .failed(failure) = result.outcome else {
                return XCTFail("Expected typed failure for HTTP \(status)")
            }
            XCTAssertEqual(failure.kind, expected)
            XCTAssertEqual(failure.statusCode, status)
            let count = await client.requestCount
            XCTAssertEqual(count, 1)
        }
    }

    func testRateLimitAndSelectedServerErrorsRetry() async throws {
        for status in [429, 500, 502, 503, 504] {
            let client = ScriptedHTTPClient([
                .response(status, Data()),
                .response(200, try json(["text": "recovered"]))
            ])
            let transcriber = makeTranscriber(
                .openai,
                realtime: client,
                retryPolicy: .init(maxAttempts: 2, baseDelay: 0)
            )
            let result = await transcriber.transcribe(.init(audio: audio))
            XCTAssertEqual(result.text, "recovered")
            XCTAssertEqual(result.retryCount, 1)
            let count = await client.requestCount
            XCTAssertEqual(count, 2)
        }
    }

    func testRetryExhaustionIsExplicit() async {
        let client = ScriptedHTTPClient([
            .response(429, Data()),
            .response(503, Data()),
            .response(500, Data())
        ])
        let transcriber = makeTranscriber(
            .openai,
            realtime: client,
            retryPolicy: .init(maxAttempts: 3, baseDelay: 0)
        )

        let result = await transcriber.transcribe(.init(audio: audio))

        guard case let .failed(failure) = result.outcome else {
            return XCTFail("Expected retry exhaustion")
        }
        XCTAssertEqual(failure.kind, .retryExhausted)
        let count = await client.requestCount
        XCTAssertEqual(count, 3)
    }

    func testMalformedResponseAndTimeoutAreDistinct() async {
        let malformed = ScriptedHTTPClient([.response(200, Data("not-json".utf8))])
        let malformedResult = await makeTranscriber(.openai, realtime: malformed)
            .transcribe(.init(audio: audio))
        guard case let .failed(failure) = malformedResult.outcome else {
            return XCTFail("Expected malformed response")
        }
        XCTAssertEqual(failure.kind, .malformedResponse)

        let timeout = ScriptedHTTPClient([.urlError(.timedOut)])
        let timeoutResult = await makeTranscriber(
            .openai,
            realtime: timeout,
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)
        ).transcribe(.init(audio: audio))
        XCTAssertEqual(timeoutResult.outcome, .timedOut)
    }

    func testTaskCancellationReturnsAborted() async {
        let client = ScriptedHTTPClient([.waitForCancellation])
        let transcriber = makeTranscriber(.openai, realtime: client)
        let samples = audio
        let task = Task { await transcriber.transcribe(.init(audio: samples)) }
        while await client.requestCount == 0 { await Task.yield() }

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.outcome, .aborted)
    }

    func testFilePathUsesDedicatedClientAndRealMIME() async throws {
        let realtime = ScriptedHTTPClient([])
        let file = ScriptedHTTPClient([.response(200, try json(["text": "from file"]))])
        let transcriber = makeTranscriber(.openai, realtime: realtime, file: file)
        let url = try temporaryFile(extension: "mp3", data: Data("ID3fixture".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await transcriber.transcribeFile(.init(url: url)) { _ in }

        XCTAssertEqual(result.text, "from file")
        let realtimeCount = await realtime.requestCount
        let fileCount = await file.requestCount
        XCTAssertEqual(realtimeCount, 0)
        XCTAssertEqual(fileCount, 1)
        let capturedRequest = await file.request(at: 0)
        let body = try XCTUnwrap(String(data: capturedRequest.httpBody ?? Data(), encoding: .utf8))
        XCTAssertTrue(body.contains("Content-Type: audio/mpeg"))
        XCTAssertTrue(body.contains("filename=\"fixture.mp3\""))
    }

    func testRawAACIsDecodedAndUploadedAsWAVInsteadOfRelabeledBytes() async throws {
        let file = ScriptedHTTPClient([.response(200, try json(["text": "decoded"]))])
        let transcriber = makeTranscriber(.openai, realtime: ScriptedHTTPClient([]), file: file)
        let source = fixtureURL("signal.aac")
        let original = try Data(contentsOf: source)

        let result = await transcriber.transcribeFile(.init(url: source)) { _ in }

        XCTAssertEqual(result.text, "decoded")
        XCTAssertEqual(result.segmentCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let capturedRequest = await file.request(at: 0)
        let body = capturedRequest.httpBody ?? Data()
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("Content-Type: audio/wav"))
        XCTAssertTrue(bodyText.contains("filename=\"segment-1.wav\""))
        XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
    }

    func testSupportedFixtureMatrixReachesProviderAsBoundedWAVSegments() async throws {
        let fixtureNames = [
            "signal-16k-mono.wav",
            "signal-44k-mono.wav",
            "signal-48k-stereo.wav",
            "signal-48k-stereo.caf",
            "signal.m4a",
            "signal.aac"
        ]
        let file = ScriptedHTTPClient(try fixtureNames.map { name in
            .response(200, try json(["text": name]))
        })
        let transcriber = makeTranscriber(
            .openai,
            realtime: ScriptedHTTPClient([]),
            file: file,
            maxInlineFileBytes: 1
        )

        for name in fixtureNames {
            let source = fixtureURL(name)
            let original = try Data(contentsOf: source)
            let result = await transcriber.transcribeFile(.init(url: source)) { _ in }
            XCTAssertEqual(result.text, name)
            XCTAssertEqual(result.segmentCount, 1)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }

        let requestCount = await file.requestCount
        XCTAssertEqual(requestCount, fixtureNames.count)
        for index in fixtureNames.indices {
            let request = await file.request(at: index)
            let body = request.httpBody ?? Data()
            XCTAssertNotNil(body.range(of: Data("Content-Type: audio/wav".utf8)))
            XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
        }
    }

    func testMIMETypeDetectionCoversSupportedContainers() {
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "fixture.bin"),
            header: Data("RIFF0000WAVE".utf8)
        ), .wav)
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "fixture.bin"),
            header: Data("ID3fixture".utf8)
        ), .mp3)
        XCTAssertEqual(FileMediaType.detect(url: URL(fileURLWithPath: "fixture.m4a")), .m4a)
        XCTAssertEqual(FileMediaType.detect(url: URL(fileURLWithPath: "fixture.mov")), .mov)
    }

    func testMediaDetectionUsesContainerBytesBeforeExtension() {
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "fixture.mp3"),
            header: Data("RIFF0000WAVE".utf8)
        ), .wav)
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "fixture.bin"),
            header: Data("caff\u{0}\u{1}\u{0}\u{0}".utf8)
        ), .caf)
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "fixture.bin"),
            header: Data("OggSfixture".utf8)
        ), .ogg)
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "fixture.bin"),
            header: Data([0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC])
        ), .aac)
        XCTAssertNil(FileMediaType.detect(
            url: URL(fileURLWithPath: "fixture.wav"),
            header: Data("not audio bytes".utf8)
        ))
        XCTAssertNil(FileMediaType.detect(
            url: URL(fileURLWithPath: "empty.wav"),
            header: Data()
        ))
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "mislabeled.mp4"),
            header: try? Data(contentsOf: fixtureURL("signal.m4a")).prefix(64)
        ), .m4a)
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "mislabeled.m4a"),
            header: Data([0, 0, 0, 20]) + Data("ftypqt  ".utf8)
        ), .mov)
        XCTAssertEqual(FileMediaType.detect(
            url: URL(fileURLWithPath: "mislabeled.ogg"),
            header: try? Data(contentsOf: fixtureURL("signal.opus")).prefix(64)
        ), .opus)
    }

    func testMediaCapabilityCatalogMatchesDecodePolicies() {
        XCTAssertEqual(MediaFormatCapabilities.policy(for: .wav), .nativeDecode)
        XCTAssertEqual(MediaFormatCapabilities.policy(for: .caf), .nativeDecode)
        XCTAssertEqual(MediaFormatCapabilities.policy(for: .aac), .coreAudioConversion)
        XCTAssertEqual(MediaFormatCapabilities.policy(for: .ogg), .unsupported)
        XCTAssertEqual(MediaFormatCapabilities.policy(for: .opus), .unsupported)
        XCTAssertTrue(MediaFormatCapabilities.supportedExtensions.contains("caf"))
        XCTAssertTrue(MediaFormatCapabilities.supportedExtensions.contains("aac"))
        XCTAssertFalse(MediaFormatCapabilities.supportedExtensions.contains("ogg"))
        XCTAssertFalse(MediaFormatCapabilities.supportedExtensions.contains("opus"))
    }

    func testWAVEncodingHasCanonicalHeaderAndClampsSamples() {
        let wav = CloudSTTTranscriber.makeWAVData(from: [-2, 0, 2])
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(wav.count, 50)
    }

    func testLargeFileIsSegmentedInOrderWithProgressAndNoInputMutation() async throws {
        let file = ScriptedHTTPClient([
            .response(200, try json(["text": "first"])),
            .response(200, try json(["text": "second"])),
            .response(200, try json(["text": "third"]))
        ])
        let transcriber = makeTranscriber(
            .openai,
            realtime: ScriptedHTTPClient([]),
            file: file,
            maxInlineFileBytes: 1
        )
        let samples = [Float](repeating: 0.05, count: 16_000 * 61)
        let original = CloudSTTTranscriber.makeWAVData(from: samples)
        let url = try temporaryFile(extension: "wav", data: original)
        let directory = url.deletingLastPathComponent()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let progress = ProgressRecorder()

        let result = await transcriber.transcribeFile(.init(url: url)) {
            progress.append($0)
        }

        XCTAssertEqual(result.text, "first second third")
        XCTAssertEqual(result.segmentCount, 3)
        let requestCount = await file.requestCount
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), filesBefore)
        let updates = progress.snapshot
        XCTAssertEqual(updates.first?.stage, .preparing)
        XCTAssertTrue(updates.contains { $0.stage == .decoding })
        XCTAssertEqual(updates.last?.stage, .completed)
        let completed = updates.filter { $0.stage == .transcribing }.map(\.completedUnits)
        XCTAssertEqual(completed, [1, 2, 3])
    }

    func testSegmentedFileCancellationStopsCurrentRequestAndPreservesInput() async throws {
        let file = ScriptedHTTPClient([.waitForCancellation])
        let transcriber = makeTranscriber(
            .openai,
            realtime: ScriptedHTTPClient([]),
            file: file,
            maxInlineFileBytes: 1
        )
        let original = CloudSTTTranscriber.makeWAVData(
            from: [Float](repeating: 0.05, count: 16_000)
        )
        let url = try temporaryFile(extension: "wav", data: original)
        let task = Task { await transcriber.transcribeFile(.init(url: url)) { _ in } }
        while await file.requestCount == 0 { await Task.yield() }

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func makeTranscriber(
        _ backend: CloudSTTBackend,
        realtime: any HTTPDataClient,
        file: (any HTTPDataClient)? = nil,
        retryPolicy: CloudRetryPolicy = .init(maxAttempts: 1, baseDelay: 0),
        maxInlineFileBytes: Int = 12 * 1_024 * 1_024
    ) -> CloudSTTTranscriber {
        CloudSTTTranscriber(
            backend: backend,
            modelName: "fixture-model",
            apiKey: "fixture-key",
            realtimeClient: realtime,
            fileClient: file ?? realtime,
            retryPolicy: retryPolicy,
            maxInlineFileBytes: maxInlineFileBytes,
            sleep: noDelay,
            jitter: { 0.5 }
        )
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func temporaryFile(extension suffix: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.\(suffix)")
        try data.write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Media/\(name)")
    }
}
