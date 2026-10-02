import Foundation
import Testing
@testable import CNSCore

private final class ScriptedModelURLProtocol: URLProtocol, @unchecked Sendable {
    struct Step: Sendable {
        let method: String
        let statusCode: Int?
        let headers: [String: String]
        let chunks: [Data]
        let errorCode: URLError.Code?

        init(
            method: String,
            statusCode: Int,
            headers: [String: String],
            chunks: [Data]
        ) {
            self.method = method
            self.statusCode = statusCode
            self.headers = headers
            self.chunks = chunks
            errorCode = nil
        }

        init(method: String, errorCode: URLError.Code) {
            self.method = method
            statusCode = nil
            headers = [:]
            chunks = []
            self.errorCode = errorCode
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [Step] = []
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []

    static func install(_ newSteps: [Step]) {
        lock.withLock {
            steps = newSteps
            capturedRequests = []
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let step = Self.lock.withLock { () -> Step? in
            Self.capturedRequests.append(request)
            guard !Self.steps.isEmpty else { return nil }
            return Self.steps.removeFirst()
        }
        guard let step, step.method == request.httpMethod else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let errorCode = step.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }
        guard let statusCode = step.statusCode else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: step.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in step.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor RetrySleepGate {
    private var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() {
        hasEntered = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
@Suite("ModelDownloader network integration", .serialized)
struct ModelDownloaderNetworkTests {
    private let modelData = Data("lmgg-network-fixture".utf8)

    @Test("HEAD success followed by GET 404 fails after one GET")
    func get404IsTerminal() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(method: "GET", statusCode: 404, headers: [:], chunks: [])
        ])
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected terminal failure")
            return
        }
        #expect(Self.getRequests.count == 1)
    }

    @Test("GET 500 retries exactly three attempts")
    func boundedServerRetries() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(method: "GET", statusCode: 500, headers: [:], chunks: []),
            .init(method: "GET", statusCode: 500, headers: [:], chunks: []),
            .init(method: "GET", statusCode: 500, headers: [:], chunks: [])
        ])
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected retries to terminate in failure")
            return
        }
        #expect(Self.getRequests.count == 3)
    }

    @Test("A rejected range performs one fresh GET and completes")
    func rejectedResumeRestartsOnce() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(
                method: "GET",
                statusCode: 200,
                headers: ["Content-Length": String(modelData.count)],
                chunks: [modelData]
            ),
            .init(
                method: "GET",
                statusCode: 200,
                headers: ["Content-Length": String(modelData.count)],
                chunks: [modelData]
            )
        ], resumePrefixLength: 5)
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        #expect(context.downloader.state == .completed)
        let requests = Self.getRequests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Range") == "bytes=5-")
        #expect(requests[1].value(forHTTPHeaderField: "Range") == nil)
    }

    @Test("A fresh request with an invalid response cannot restart again")
    func invalidFreshResponseFails() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(
                method: "GET",
                statusCode: 200,
                headers: ["Content-Length": String(modelData.count)],
                chunks: [modelData]
            ),
            .init(
                method: "GET",
                statusCode: 206,
                headers: [
                    "Content-Length": String(modelData.count),
                    "Content-Range": "bytes 0-\(modelData.count - 1)/\(modelData.count)"
                ],
                chunks: [modelData]
            )
        ], resumePrefixLength: 5)
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected invalid fresh response to fail")
            return
        }
        #expect(Self.getRequests.count == 2)
    }

    @Test("Unknown response length cannot write beyond the manifest size")
    func oversizedUnknownLengthIsRejectedBeforeWrite() async throws {
        let oversized = modelData + Data("extra".utf8)
        let context = try makeContext(steps: [
            headStep(),
            .init(method: "GET", statusCode: 200, headers: [:], chunks: [oversized])
        ])
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected oversized transfer to fail")
            return
        }
        let partial = context.paths.modelsDirectory
            .appendingPathComponent(".downloads/\(context.model.id)/artifact.partial")
        let bytes = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        #expect(bytes <= Int64(modelData.count))
    }

    @Test("Transient network errors retry exactly three attempts")
    func boundedNetworkRetries() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(method: "GET", errorCode: .networkConnectionLost),
            .init(method: "GET", errorCode: .networkConnectionLost),
            .init(method: "GET", errorCode: .networkConnectionLost)
        ])
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected retries to terminate in failure")
            return
        }
        #expect(Self.getRequests.count == 3)
    }

    @Test("A changed ETag rejects the body before any bytes are written")
    func changedETagIsRejectedBeforeWrite() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(
                method: "GET",
                statusCode: 200,
                headers: [
                    "Content-Length": String(modelData.count),
                    "ETag": "changed-etag"
                ],
                chunks: [modelData]
            )
        ])
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected validator mismatch to fail")
            return
        }
        #expect(try partialSize(context) == 0)
    }

    @Test("HTTP 416 is terminal after one GET")
    func rangeNotSatisfiableIsTerminal() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(method: "GET", statusCode: 416, headers: [:], chunks: [])
        ])
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected 416 to fail")
            return
        }
        #expect(Self.getRequests.count == 1)
    }

    @Test("A zero response length is rejected for a non-empty artifact")
    func zeroResponseLengthIsRejected() async throws {
        let context = try makeContext(steps: [
            headStep(),
            .init(method: "GET", statusCode: 200, headers: ["Content-Length": "0"], chunks: [])
        ])
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForTerminal(context.downloader)

        guard case .failed = context.downloader.state else {
            Issue.record("Expected zero-length response to fail")
            return
        }
    }

    @Test("Cancelling during retry backoff prevents another request")
    func retryBackoffIsCancellable() async throws {
        let context = try makeContext(
            steps: [
                headStep(),
                .init(method: "GET", statusCode: 500, headers: [:], chunks: []),
                .init(
                    method: "GET",
                    statusCode: 200,
                    headers: ["Content-Length": String(modelData.count)],
                    chunks: [modelData]
                )
            ],
            retrySleep: { _ in try await Task.sleep(for: .seconds(30)) }
        )
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForRequestCount(1)
        try await Task.sleep(for: .milliseconds(20))
        context.downloader.cancel()
        try await Task.sleep(for: .milliseconds(50))

        #expect(context.downloader.state == .cancelled)
        #expect(Self.getRequests.count == 1)
    }

    @Test("A non-cooperative retry waiter cannot overwrite cancellation")
    func lateRetryFailureCannotReplaceCancelledState() async throws {
        let retrySleepGate = RetrySleepGate()
        let context = try makeContext(
            steps: [
                headStep(),
                .init(method: "GET", statusCode: 500, headers: [:], chunks: [])
            ],
            retrySleep: { _ in
                await retrySleepGate.enter()
                // Sleep long enough that a slow CI won't expire it before the test cancels.
                // Cancellation will interrupt this sleep immediately.
                try? await Task.sleep(for: .seconds(10))
                throw URLError(.cannotConnectToHost)
            }
        )
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForRequestCount(1)
        await retrySleepGate.waitUntilEntered()
        context.downloader.cancel()
        try await Task.sleep(for: .milliseconds(50))

        #expect(context.downloader.state == .cancelled)
    }

    @Test("A callback from an invalidated transfer cannot mutate progress")
    func staleTransferCallbackIsIgnored() async throws {
        let context = try makeContext(
            steps: [
                headStep(),
                .init(method: "GET", statusCode: 500, headers: [:], chunks: [])
            ],
            retrySleep: { _ in try await Task.sleep(for: .seconds(30)) }
        )
        defer { context.cleanup() }

        context.downloader.start(model: context.model)
        try await waitForRequestCount(1)
        try await Task.sleep(for: .milliseconds(20))
        let identity = context.downloader.callbackIdentityForTesting
        let before = context.downloader.downloadedBytes

        context.downloader.handleProgress(
            artifactBytes: Int64(modelData.count),
            generation: identity.generation,
            transferGeneration: identity.transferGeneration - 1
        )

        #expect(context.downloader.downloadedBytes == before)
        context.downloader.cancel()
    }

    private static var getRequests: [URLRequest] {
        ScriptedModelURLProtocol.requests.filter { $0.httpMethod == "GET" }
    }

    private func headStep() -> ScriptedModelURLProtocol.Step {
        .init(
            method: "HEAD",
            statusCode: 200,
            headers: [
                "Content-Length": String(modelData.count),
                "Accept-Ranges": "bytes",
                "ETag": "fixture-etag"
            ],
            chunks: []
        )
    }

    private func makeContext(
        steps: [ScriptedModelURLProtocol.Step],
        resumePrefixLength: Int = 0,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) throws -> DownloadTestContext {
        ScriptedModelURLProtocol.install(steps)
        let configuration: @Sendable () -> URLSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScriptedModelURLProtocol.self]
            return configuration
        }
        let paths = testPaths()
        try paths.ensureModelsDirectory()
        let model = singleFileModel(
            data: modelData,
            id: "network-\(UUID().uuidString)"
        )
        if resumePrefixLength > 0 {
            let artifact = model.artifacts[0]
            let directory = paths.modelsDirectory
                .appendingPathComponent(".downloads", isDirectory: true)
                .appendingPathComponent(model.id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(modelData.prefix(resumePrefixLength))
                .write(to: directory.appendingPathComponent("artifact.partial"))
            let metadata = DownloadResumeMetadata(
                modelID: model.id,
                manifestVersion: model.manifestVersion,
                sourceRevision: model.sourceRevision,
                artifactPath: artifact.relativePath,
                downloadURL: artifact.downloadURL,
                expectedSize: artifact.expectedSize,
                sha256: artifact.sha256,
                etag: "fixture-etag",
                lastModified: nil
            )
            try JSONEncoder().encode(metadata)
                .write(to: directory.appendingPathComponent("metadata.json"))
        }
        let inspector = URLSessionArtifactMetadataInspector(
            session: URLSession(configuration: configuration())
        )
        let downloader = ModelDownloader(
            paths: paths,
            metadataInspector: inspector,
            diskCapacity: { _ in 1_000_000_000 },
            sessionConfiguration: configuration,
            retrySleep: retrySleep
        )
        return DownloadTestContext(paths: paths, model: model, downloader: downloader)
    }

    private func waitForTerminal(_ downloader: ModelDownloader) async throws {
        let deadline = Date().addingTimeInterval(3)
        while downloader.state == .downloading || downloader.state == .validating {
            guard Date() < deadline else {
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForRequestCount(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Self.getRequests.count < count {
            guard Date() < deadline else {
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func partialSize(_ context: DownloadTestContext) throws -> Int64 {
        let partial = context.paths.modelsDirectory
            .appendingPathComponent(".downloads/\(context.model.id)/artifact.partial")
        return Int64((try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }
}

@MainActor
private struct DownloadTestContext {
    let paths: Paths
    let model: ModelInfo
    let downloader: ModelDownloader

    func cleanup() {
        try? FileManager.default.removeItem(at: paths.dataDirectory)
    }
}
