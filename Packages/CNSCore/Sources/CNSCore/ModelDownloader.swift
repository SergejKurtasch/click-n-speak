import Foundation

public struct RemoteArtifactMetadata: Sendable, Equatable {
    public let etag: String?
    public let lastModified: String?
    public let acceptsByteRanges: Bool
    public let contentLength: Int64?

    public init(
        etag: String?,
        lastModified: String?,
        acceptsByteRanges: Bool,
        contentLength: Int64?
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.acceptsByteRanges = acceptsByteRanges
        self.contentLength = contentLength
    }
}

public enum ModelResponseAction: Sendable, Equatable {
    case accept
    case restartFresh
    case retry(after: TimeInterval)
    case fail
}

public struct ModelTransferPolicy: Sendable, Equatable {
    public let attempt: Int
    public let maxAttempts: Int
    public let retryAfter: TimeInterval?

    public init(attempt: Int, maxAttempts: Int = 3, retryAfter: TimeInterval? = nil) {
        self.attempt = max(1, attempt)
        self.maxAttempts = max(1, maxAttempts)
        self.retryAfter = retryAfter
    }

    public func responseAction(
        statusCode: Int,
        offset: Int64,
        contentRange: String?,
        responseLength: Int64?,
        expectedSize: Int64,
        didRestartFresh: Bool
    ) -> ModelResponseAction {
        if offset > 0, !didRestartFresh, statusCode == 200 {
            return .restartFresh
        }
        guard (200..<300).contains(statusCode) else {
            return failureOrBoundedRetry(statusCode)
        }
        guard expectedSize > 0 else { return .fail }
        if offset == 0 {
            guard statusCode == 200,
                  responseLength == nil || responseLength == expectedSize else {
                return .fail
            }
            return .accept
        }
        guard statusCode == 206,
              let range = Self.parseContentRange(contentRange),
              range.start == offset,
              range.end >= range.start,
              range.end == expectedSize - 1,
              range.total == expectedSize else {
            return .fail
        }
        let expectedResponseLength = range.end - range.start + 1
        guard responseLength == nil || responseLength == expectedResponseLength else {
            return .fail
        }
        return .accept
    }

    public func failureOrBoundedRetry(_ statusCode: Int) -> ModelResponseAction {
        let transient = [429, 500, 502, 503, 504].contains(statusCode)
        guard transient, attempt < maxAttempts else { return .fail }
        let exponent = min(attempt - 1, 4)
        let backoff = TimeInterval(1 << exponent)
        let requested = max(backoff, retryAfter ?? 0)
        return .retry(after: min(30, requested))
    }

    func failureOrBoundedRetry(_ error: URLError) -> ModelResponseAction {
        let transient: Set<URLError.Code> = [
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .resourceUnavailable,
            .timedOut
        ]
        guard transient.contains(error.code), attempt < maxAttempts else { return .fail }
        let exponent = min(attempt - 1, 4)
        return .retry(after: TimeInterval(1 << exponent))
    }

    private static func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value else { return nil }
        let components = value.lowercased().split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "bytes" else { return nil }
        let rangeAndTotal = components[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]) else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else { return nil }
        return (start, end, total)
    }
}

public protocol ArtifactMetadataInspecting: Sendable {
    func metadata(for url: URL) async throws -> RemoteArtifactMetadata
}

public struct URLSessionArtifactMetadataInspector: ArtifactMetadataInspecting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func metadata(for url: URL) async throws -> RemoteArtifactMetadata {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard data.count <= 64 * 1_024,
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        return RemoteArtifactMetadata(
            etag: headers["etag"],
            lastModified: headers["last-modified"],
            acceptsByteRanges: headers["accept-ranges"]?.lowercased() == "bytes",
            contentLength: headers["content-length"].flatMap(Int64.init)
        )
    }
}

struct DownloadResumeMetadata: Codable, Sendable, Equatable {
    let modelID: String
    let manifestVersion: Int
    let sourceRevision: String
    let artifactPath: String
    let downloadURL: URL
    let expectedSize: Int64
    let sha256: String
    let etag: String?
    let lastModified: String?
}

enum ModelResumePolicy {
    static func canResume(
        saved: DownloadResumeMetadata,
        model: ModelInfo,
        artifact: ModelArtifact,
        remote: RemoteArtifactMetadata
    ) -> Bool {
        guard saved.modelID == model.id,
              saved.manifestVersion == model.manifestVersion,
              saved.sourceRevision == model.sourceRevision,
              saved.artifactPath == artifact.relativePath,
              saved.downloadURL == artifact.downloadURL,
              saved.expectedSize == artifact.expectedSize,
              saved.sha256 == artifact.sha256,
              remote.acceptsByteRanges,
              remote.contentLength == nil || remote.contentLength == artifact.expectedSize else {
            return false
        }
        if let savedETag = saved.etag, let remoteETag = remote.etag {
            return savedETag == remoteETag
        }
        if let savedDate = saved.lastModified, let remoteDate = remote.lastModified {
            return savedDate == remoteDate
        }
        return false
    }

    static func responseAllowsResume(
        statusCode: Int,
        contentRange: String?,
        offset: Int64,
        expectedSize: Int64,
        responseLength: Int64?
    ) -> Bool {
        ModelTransferPolicy(attempt: 1).responseAction(
            statusCode: statusCode,
            offset: offset,
            contentRange: contentRange,
            responseLength: responseLength,
            expectedSize: expectedSize,
            didRestartFresh: false
        ) == .accept
    }
}

/// Streams pinned model artifacts into durable `.downloads` partials. An app
/// termination therefore loses no acknowledged bytes: relaunch issues a
/// validator-protected HTTP range request and final activation still requires
/// exact size, format, and SHA-256 checks.
@MainActor
public final class ModelDownloader: NSObject {
    public enum State: Sendable, Equatable {
        case idle
        case downloading
        case validating
        case completed
        case failed(String)
        case cancelled
    }

    public private(set) var state: State = .idle
    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var totalBytes: Int64?
    public private(set) var bytesPerSecond: Double = 0

    public var estimatedTimeRemaining: TimeInterval? {
        guard bytesPerSecond > 0, let totalBytes else { return nil }
        let remaining = totalBytes - downloadedBytes
        return remaining > 0 ? Double(remaining) / bytesPerSecond : nil
    }

    public var onProgress: ((Int64, Int64?) -> Void)?
    public var onValidationStarted: (() -> Void)?
    public var onDone: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onCancelled: (() -> Void)?

    private let paths: Paths
    private let registry: ModelArtifactAccessRegistry
    private let metadataInspector: any ArtifactMetadataInspecting
    private let diskCapacity: @Sendable (URL) -> Int64
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void
    private let log: (String) -> Void

    private var dataTask: URLSessionDataTask?
    private var preparationTask: Task<Void, Never>?
    private var session: URLSession?
    private var delegateHandler: StreamingDownloadDelegate?
    private var activeModel: ModelInfo?
    private var artifactQueue: [ModelArtifact] = []
    private var currentArtifact: ModelArtifact?
    private var stagingURL: URL?
    private var completedArtifactBytes: Int64 = 0
    private var accessTokens: [UUID] = []
    private var generation = 0
    private var transferGeneration = 0
    private var lastProgressCallbackDate: Date = .distantPast
    private var speedSamples: [(date: Date, bytes: Int64)] = []

    public init(
        paths: Paths,
        registry: ModelArtifactAccessRegistry = .shared,
        metadataInspector: any ArtifactMetadataInspecting = URLSessionArtifactMetadataInspector(),
        diskCapacity: @escaping @Sendable (URL) -> Int64 = ModelManager.availableDiskCapacity,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = {
            .default
        },
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.paths = paths
        self.registry = registry
        self.metadataInspector = metadataInspector
        self.diskCapacity = diskCapacity
        self.sessionConfiguration = sessionConfiguration
        self.retrySleep = retrySleep
        self.log = log
        super.init()
    }

    public func start(model: ModelInfo) {
        guard state != .downloading, state != .validating else {
            log("ModelDownloader: another model operation is active")
            return
        }
        generation += 1
        let currentGeneration = generation
        let taskID = UUID()
        activeModel = model
        state = .downloading
        if let token = try? registry.acquireUse(modelID: model.id, reason: .downloading(taskID: taskID)) {
            accessTokens.append(token)
        } else {
            applyError("Model artifact is reserved for deletion", generation: currentGeneration)
            return
        }
        downloadedBytes = 0
        totalBytes = model.artifacts.reduce(0) { $0 + $1.expectedSize }
        bytesPerSecond = 0
        speedSamples.removeAll()
        lastProgressCallbackDate = .distantPast

        do {
            try paths.ensureModelsDirectory()
            try ModelManager.checkDiskCapacity(
                requiredBytes: remainingDownloadBytes(model: model),
                availableBytes: diskCapacity(paths.modelsDirectory)
            )
            try prepareStaging(model: model)
        } catch {
            applyError(error.localizedDescription, generation: currentGeneration)
            return
        }
        startNextArtifact(generation: currentGeneration)
    }

    public func cancel() {
        guard state == .downloading else { return }
        let currentGeneration = generation
        preparationTask?.cancel()
        preparationTask = nil
        dataTask?.cancel()
        applyCancelled(generation: currentGeneration)
    }

    public var canResume: Bool {
        guard let activeModel else { return false }
        return hasDurableResumeData(model: activeModel)
    }

    public func canResume(model: ModelInfo) -> Bool {
        hasDurableResumeData(model: model)
    }

    public func clearResumeData() {
        guard let activeModel else { return }
        removeResumeFiles(model: activeModel)
    }

    func handleProgress(
        artifactBytes: Int64,
        generation callbackGeneration: Int,
        transferGeneration callbackTransferGeneration: Int
    ) {
        guard callbackGeneration == generation,
              callbackTransferGeneration == transferGeneration,
              state == .downloading else { return }
        downloadedBytes = completedArtifactBytes + artifactBytes
        let now = Date()
        speedSamples.append((now, downloadedBytes))
        speedSamples.removeAll { now.timeIntervalSince($0.date) > 2 }
        if let first = speedSamples.first, speedSamples.count > 1 {
            let interval = now.timeIntervalSince(first.date)
            if interval > 0 {
                bytesPerSecond = max(0, Double(downloadedBytes - first.bytes) / interval)
            }
        }
        if now.timeIntervalSince(lastProgressCallbackDate) >= 0.2 {
            lastProgressCallbackDate = now
            onProgress?(downloadedBytes, totalBytes)
        }
    }

    #if DEBUG
    var callbackIdentityForTesting: (generation: Int, transferGeneration: Int) {
        (generation, transferGeneration)
    }
    #endif

    fileprivate func handleFinishedDownload(
        transferURL: URL,
        generation callbackGeneration: Int,
        transferGeneration callbackTransferGeneration: Int
    ) {
        guard callbackGeneration == generation,
              callbackTransferGeneration == transferGeneration,
              state == .downloading,
              let model = activeModel,
              let artifact = currentArtifact,
              let stagingURL else { return }
        do {
            let size = Int64((try transferURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            guard size == artifact.expectedSize else {
                throw ModelValidationError.wrongSize(
                    path: artifact.relativePath,
                    expected: artifact.expectedSize,
                    actual: size
                )
            }
            let destination: URL
            switch model.storage {
            case .singleFile:
                destination = stagingURL
            case .snapshot:
                destination = stagingURL.appendingPathComponent(artifact.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: transferURL, to: destination)
            completedArtifactBytes += artifact.expectedSize
            downloadedBytes = completedArtifactBytes
            currentArtifact = nil
            removeResumeFiles(model: model)
            invalidateTransferSession()
            startNextArtifact(generation: callbackGeneration)
        } catch {
            applyError(error.localizedDescription, generation: callbackGeneration)
        }
    }

    fileprivate func handleRejectedResume(
        remote: RemoteArtifactMetadata,
        generation callbackGeneration: Int,
        transferGeneration callbackTransferGeneration: Int,
        attempt: Int
    ) {
        guard callbackGeneration == generation,
              callbackTransferGeneration == transferGeneration,
              state == .downloading,
              let model = activeModel,
              let artifact = currentArtifact else { return }
        log("ModelDownloader: server rejected safe resume; restarting current artifact")
        invalidateTransferSession()
        removeResumeFiles(model: model)
        beginTransfer(
            artifact: artifact,
            model: model,
            remote: remote,
            generation: callbackGeneration,
            forceFresh: true,
            attempt: attempt,
            didRestartFresh: true
        )
    }

    fileprivate func handleRetry(
        remote: RemoteArtifactMetadata,
        generation callbackGeneration: Int,
        transferGeneration callbackTransferGeneration: Int,
        attempt: Int,
        didRestartFresh: Bool,
        delay: TimeInterval
    ) {
        guard callbackGeneration == generation,
              callbackTransferGeneration == transferGeneration,
              state == .downloading,
              let model = activeModel,
              let artifact = currentArtifact else { return }
        invalidateTransferSession()
        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await retrySleep(delay)
                try Task.checkCancellation()
                guard callbackGeneration == generation, state == .downloading else { return }
                beginTransfer(
                    artifact: artifact,
                    model: model,
                    remote: remote,
                    generation: callbackGeneration,
                    attempt: attempt + 1,
                    didRestartFresh: didRestartFresh
                )
            } catch is CancellationError {
                return
            } catch {
                applyError(error.localizedDescription, generation: callbackGeneration)
            }
        }
    }

    fileprivate func handleError(
        _ error: Error,
        generation callbackGeneration: Int,
        transferGeneration callbackTransferGeneration: Int
    ) {
        guard callbackGeneration == generation,
              callbackTransferGeneration == transferGeneration else { return }
        let urlError = error as? URLError
        if urlError?.code == .cancelled { return }
        applyError(error.localizedDescription, generation: callbackGeneration)
    }

    private func startNextArtifact(generation currentGeneration: Int) {
        guard currentGeneration == generation,
              state == .downloading,
              let model = activeModel else { return }
        guard !artifactQueue.isEmpty else {
            validateAndActivate(model: model, generation: currentGeneration)
            return
        }
        let artifact = artifactQueue.removeFirst()
        currentArtifact = artifact
        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let remote = try await metadataInspector.metadata(for: artifact.downloadURL)
                try Task.checkCancellation()
                guard currentGeneration == generation, state == .downloading else { return }
                guard remote.contentLength == nil || remote.contentLength == artifact.expectedSize else {
                    throw ModelValidationError.wrongSize(
                        path: artifact.relativePath,
                        expected: artifact.expectedSize,
                        actual: remote.contentLength ?? -1
                    )
                }
                beginTransfer(
                    artifact: artifact,
                    model: model,
                    remote: remote,
                    generation: currentGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                applyError(error.localizedDescription, generation: currentGeneration)
            }
        }
    }

    private func beginTransfer(
        artifact: ModelArtifact,
        model: ModelInfo,
        remote: RemoteArtifactMetadata,
        generation currentGeneration: Int,
        forceFresh: Bool = false,
        attempt: Int = 1,
        didRestartFresh: Bool = false
    ) {
        guard currentGeneration == generation, state == .downloading else { return }
        transferGeneration += 1
        let currentTransferGeneration = transferGeneration
        let saved = readResumeMetadata(model: model)
        let transferURL = transferDataURL(model: model)
        var existingBytes = Int64(
            (try? transferURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        let safeResume = !forceFresh && saved.map {
            ModelResumePolicy.canResume(saved: $0, model: model, artifact: artifact, remote: remote)
        } == true && existingBytes > 0 && existingBytes <= artifact.expectedSize

        if safeResume, existingBytes == artifact.expectedSize {
            handleFinishedDownload(
                transferURL: transferURL,
                generation: currentGeneration,
                transferGeneration: currentTransferGeneration
            )
            return
        }
        if !safeResume {
            removeResumeFiles(model: model)
            existingBytes = 0
        }

        do {
            let directory = resumeDirectory(model: model)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: transferURL.path) {
                guard FileManager.default.createFile(atPath: transferURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let metadata = DownloadResumeMetadata(
                modelID: model.id,
                manifestVersion: model.manifestVersion,
                sourceRevision: model.sourceRevision,
                artifactPath: artifact.relativePath,
                downloadURL: artifact.downloadURL,
                expectedSize: artifact.expectedSize,
                sha256: artifact.sha256,
                etag: remote.etag,
                lastModified: remote.lastModified
            )
            try persistResumeMetadata(metadata, model: model)

            var request = URLRequest(url: artifact.downloadURL)
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if existingBytes > 0 {
                request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
                if let validator = remote.etag ?? remote.lastModified {
                    request.setValue(validator, forHTTPHeaderField: "If-Range")
                }
                log("ModelDownloader: resuming \(model.id)/\(artifact.relativePath) at \(existingBytes)")
            } else {
                log("ModelDownloader: downloading \(model.id)/\(artifact.relativePath)")
            }

            let delegate = StreamingDownloadDelegate(
                downloader: self,
                generation: currentGeneration,
                transferURL: transferURL,
                offset: existingBytes,
                expectedSize: artifact.expectedSize,
                remote: remote,
                attempt: attempt,
                didRestartFresh: didRestartFresh,
                transferGeneration: currentTransferGeneration
            )
            let queue = OperationQueue()
            queue.name = "click-n-speak.model-download"
            queue.maxConcurrentOperationCount = 1
            let configuration = sessionConfiguration()
            configuration.timeoutIntervalForResource = 4 * 3600
            configuration.timeoutIntervalForRequest = 60
            configuration.waitsForConnectivity = true
            delegateHandler = delegate
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            dataTask = session?.dataTask(with: request)
            dataTask?.resume()
        } catch {
            applyError(error.localizedDescription, generation: currentGeneration)
        }
    }

    private func validateAndActivate(model: ModelInfo, generation currentGeneration: Int) {
        guard let stagingURL else {
            applyError("Model staging path is unavailable", generation: currentGeneration)
            return
        }
        state = .validating
        onValidationStarted?()
        onProgress?(downloadedBytes, totalBytes)
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await ModelManager.validateAndActivate(
                    stagingURL: stagingURL,
                    model: model,
                    paths: paths
                )
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                state = .completed
                downloadedBytes = totalBytes ?? downloadedBytes
                removeResumeFiles(model: model)
                invalidateTransferSession()
                onProgress?(downloadedBytes, totalBytes)
                onDone?()
            } catch is CancellationError {
                return
            } catch {
                do {
                    try ModelManager.quarantineInvalidArtifact(at: stagingURL, model: model, paths: paths)
                } catch {
                    log("ModelDownloader: staging quarantine failed: \(error.localizedDescription)")
                }
                applyError(error.localizedDescription, generation: currentGeneration)
            }
        }
    }

    private func prepareStaging(model: ModelInfo) throws {
        let partial = paths.modelsDirectory.appendingPathComponent(
            ".\(model.fileName).partial",
            isDirectory: model.storage.isSnapshot
        )
        stagingURL = partial
        if model.storage.isSnapshot {
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        }
        var queued: [ModelArtifact] = []
        completedArtifactBytes = 0
        for artifact in model.artifacts {
            let existing = model.storage.isSnapshot
                ? partial.appendingPathComponent(artifact.relativePath)
                : partial
            let size = Int64((try? existing.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            if size == artifact.expectedSize {
                completedArtifactBytes += artifact.expectedSize
            } else {
                if FileManager.default.fileExists(atPath: existing.path) {
                    try FileManager.default.removeItem(at: existing)
                }
                queued.append(artifact)
            }
        }
        artifactQueue = queued
        downloadedBytes = completedArtifactBytes
    }

    private func remainingDownloadBytes(model: ModelInfo) -> Int64 {
        let staging = paths.modelsDirectory.appendingPathComponent(".\(model.fileName).partial")
        var remaining = model.artifacts.reduce(Int64(0)) { result, artifact in
            let url = model.storage.isSnapshot
                ? staging.appendingPathComponent(artifact.relativePath)
                : staging
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return result + max(0, artifact.expectedSize - size)
        }
        if let metadata = readResumeMetadata(model: model),
           model.artifacts.contains(where: { $0.relativePath == metadata.artifactPath }) {
            let transferSize = Int64(
                (try? transferDataURL(model: model).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            remaining = max(0, remaining - min(metadata.expectedSize, transferSize))
        }
        return remaining
    }

    private func applyCancelled(generation currentGeneration: Int) {
        guard currentGeneration == generation else { return }
        state = .cancelled
        invalidateTransferSession()
        onCancelled?()
    }

    private func applyError(_ message: String, generation currentGeneration: Int) {
        guard currentGeneration == generation,
              state == .downloading || state == .validating else { return }
        log("ModelDownloader: error — \(message)")
        state = .failed(message)
        dataTask?.cancel()
        invalidateTransferSession()
        onError?(message)
    }

    private func invalidateTransferSession() {
        for token in accessTokens {
            registry.releaseUse(token)
        }
        accessTokens.removeAll()
        transferGeneration += 1
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        delegateHandler = nil
    }

    private func resumeDirectory(model: ModelInfo) -> URL {
        paths.modelsDirectory.appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
    }

    private func transferDataURL(model: ModelInfo) -> URL {
        resumeDirectory(model: model).appendingPathComponent("artifact.partial")
    }

    private func resumeMetadataURL(model: ModelInfo) -> URL {
        resumeDirectory(model: model).appendingPathComponent("metadata.json")
    }

    private func persistResumeMetadata(
        _ metadata: DownloadResumeMetadata,
        model: ModelInfo
    ) throws {
        let directory = resumeDirectory(model: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(
            to: resumeMetadataURL(model: model),
            options: [.atomic]
        )
    }

    private func readResumeMetadata(model: ModelInfo) -> DownloadResumeMetadata? {
        guard let data = try? Data(contentsOf: resumeMetadataURL(model: model)) else { return nil }
        return try? JSONDecoder().decode(DownloadResumeMetadata.self, from: data)
    }

    private func hasDurableResumeData(model: ModelInfo) -> Bool {
        let size = Int64(
            (try? transferDataURL(model: model).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        return size > 0 && size <= (readResumeMetadata(model: model)?.expectedSize ?? -1)
    }

    private func removeResumeFiles(model: ModelInfo) {
        try? FileManager.default.removeItem(at: resumeDirectory(model: model))
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var downloader: ModelDownloader?
    private let generation: Int
    private let transferURL: URL
    private let offset: Int64
    private let expectedSize: Int64
    private let remote: RemoteArtifactMetadata
    private let attempt: Int
    private let didRestartFresh: Bool
    private let transferGeneration: Int
    private var receivedBytes: Int64 = 0
    private var fileHandle: FileHandle?
    private var resumeRejected = false
    private var failureReported = false

    init(
        downloader: ModelDownloader,
        generation: Int,
        transferURL: URL,
        offset: Int64,
        expectedSize: Int64,
        remote: RemoteArtifactMetadata,
        attempt: Int,
        didRestartFresh: Bool,
        transferGeneration: Int
    ) {
        self.downloader = downloader
        self.generation = generation
        self.transferURL = transferURL
        self.offset = offset
        self.expectedSize = expectedSize
        self.remote = remote
        self.attempt = attempt
        self.didRestartFresh = didRestartFresh
        self.transferGeneration = transferGeneration
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            reportFailure(URLError(.badServerResponse))
            return
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let action = ModelTransferPolicy(
            attempt: attempt,
            retryAfter: retryAfter
        ).responseAction(
            statusCode: http.statusCode,
            offset: offset,
            contentRange: contentRange,
            responseLength: length,
            expectedSize: expectedSize,
            didRestartFresh: didRestartFresh
        )
        switch action {
        case .restartFresh:
            resumeRejected = true
            completionHandler(.cancel)
            guard let downloader else { return }
            Task { @MainActor in
                downloader.handleRejectedResume(
                    remote: remote,
                    generation: generation,
                    transferGeneration: transferGeneration,
                    attempt: attempt
                )
            }
            return
        case let .retry(delay):
            failureReported = true
            completionHandler(.cancel)
            guard let downloader else { return }
            Task { @MainActor in
                downloader.handleRetry(
                    remote: remote,
                    generation: generation,
                    transferGeneration: transferGeneration,
                    attempt: attempt,
                    didRestartFresh: didRestartFresh,
                    delay: delay
                )
            }
            return
        case .fail:
            completionHandler(.cancel)
            reportFailure(URLError(.badServerResponse))
            return
        case .accept:
            break
        }
        if !responseValidatorMatches(http) {
            completionHandler(.cancel)
            reportFailure(URLError(.badServerResponse))
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: transferURL)
            if offset == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                try handle.seek(toOffset: UInt64(offset))
            }
            fileHandle = handle
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            reportFailure(error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !resumeRejected, !failureReported, let fileHandle else { return }
        do {
            let remaining = expectedSize - offset - receivedBytes
            guard remaining >= 0, Int64(data.count) <= remaining else {
                dataTask.cancel()
                reportFailure(URLError(.dataLengthExceedsMaximum))
                return
            }
            try fileHandle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            guard let downloader else { return }
            Task { @MainActor in
                downloader.handleProgress(
                    artifactBytes: offset + receivedBytes,
                    generation: generation,
                    transferGeneration: transferGeneration
                )
            }
        } catch {
            dataTask.cancel()
            reportFailure(error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        try? fileHandle?.close()
        fileHandle = nil
        guard !resumeRejected, !failureReported else { return }
        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled { return }
            if let urlError,
               case let .retry(delay) = ModelTransferPolicy(attempt: attempt)
                .failureOrBoundedRetry(urlError),
               let downloader {
                failureReported = true
                Task { @MainActor in
                    downloader.handleRetry(
                        remote: remote,
                        generation: generation,
                        transferGeneration: transferGeneration,
                        attempt: attempt,
                        didRestartFresh: didRestartFresh,
                        delay: delay
                    )
                }
            } else {
                reportFailure(error)
            }
            return
        }
        guard let downloader else { return }
        Task { @MainActor in
            downloader.handleFinishedDownload(
                transferURL: transferURL,
                generation: generation,
                transferGeneration: transferGeneration
            )
        }
    }

    private nonisolated func responseValidatorMatches(_ response: HTTPURLResponse) -> Bool {
        if let expected = remote.etag,
           let actual = response.value(forHTTPHeaderField: "ETag"),
           expected != actual {
            return false
        }
        if let expected = remote.lastModified,
           let actual = response.value(forHTTPHeaderField: "Last-Modified"),
           expected != actual {
            return false
        }
        return true
    }

    private nonisolated func reportFailure(_ error: Error) {
        guard !failureReported else { return }
        failureReported = true
        guard let downloader else { return }
        Task { @MainActor in
            downloader.handleError(
                error,
                generation: generation,
                transferGeneration: transferGeneration
            )
        }
    }
}

private extension ModelStorage {
    var isSnapshot: Bool {
        if case .snapshot = self { return true }
        return false
    }
}
