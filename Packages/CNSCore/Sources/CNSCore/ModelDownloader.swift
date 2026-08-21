import Foundation

/// Downloads a model file via `URLSession` with progress reporting, cancel, and
/// resume support. Mirrors the Python `ModelDownloader` (multiprocessing +
/// `huggingface_hub.snapshot_download`) but is much simpler: a single GGUF file
/// via a direct URL, no child process.
///
/// All public state is `@MainActor` — callers can observe `state`, `downloadedBytes`,
/// and `totalBytes` from the main thread without manual dispatching.
///
/// Usage:
/// ```swift
/// let dl = ModelDownloader(paths: paths)
/// dl.onDone = { ... }
/// dl.start(model: ModelRegistry.whisperModels[0])
/// ```
@MainActor
public final class ModelDownloader: NSObject {

    // MARK: - State

    public enum State: Sendable, Equatable {
        case idle
        case downloading
        case completed
        case failed(String)
        case cancelled
    }

    public private(set) var state: State = .idle
    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var totalBytes: Int64?

    /// Download speed in bytes/second (rolling average over the last 2 seconds).
    public private(set) var bytesPerSecond: Double = 0

    /// Estimated time remaining in seconds, or nil if unknown.
    public var estimatedTimeRemaining: TimeInterval? {
        guard bytesPerSecond > 0, let total = totalBytes else { return nil }
        let remaining = total - downloadedBytes
        guard remaining > 0 else { return nil }
        return Double(remaining) / bytesPerSecond
    }

    // MARK: - Callbacks

    /// Called on main thread whenever `downloadedBytes` or `totalBytes` change.
    /// Throttled to ≥ 0.2s intervals.
    public var onProgress: ((Int64, Int64?) -> Void)?

    /// Called on main thread when the download completes successfully.
    public var onDone: (() -> Void)?

    /// Called on main thread on failure.
    public var onError: ((String) -> Void)?

    /// Called on main thread after a user-initiated cancel.
    public var onCancelled: (() -> Void)?

    // MARK: - Private

    private let paths: Paths
    private let log: (String) -> Void

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var activeModel: ModelInfo?
    private var destinationURL: URL?

    /// Saved resume data from a cancelled/interrupted download.
    private var resumeData: Data?

    /// For progress throttling (≥ 0.2s).
    private var lastProgressCallbackDate: Date = .distantPast

    /// For speed calculation.
    private var speedSamples: [(date: Date, bytes: Int64)] = []

    // MARK: - Init

    public init(paths: Paths, log: @escaping (String) -> Void = { _ in }) {
        self.paths = paths
        self.log = log
        super.init()
    }

    // MARK: - Public API

    /// Start downloading a model. If already downloading, does nothing.
    public func start(model: ModelInfo) {
        guard state != .downloading else {
            log("ModelDownloader: already downloading, ignoring start(\(model.id))")
            return
        }

        activeModel = model
        state = .downloading
        downloadedBytes = 0
        totalBytes = model.sizeEstimate
        bytesPerSecond = 0
        speedSamples.removeAll()
        lastProgressCallbackDate = .distantPast

        do {
            try paths.ensureModelsDirectory()
        } catch {
            applyError("Failed to create models directory: \(error.localizedDescription)")
            return
        }

        destinationURL = paths.modelFile(for: model)

        // Create a dedicated session with a delegate for progress callbacks.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600   // 1 hour max for large files
        config.timeoutIntervalForRequest = 60      // 60s per chunk
        let delegateHandler = DownloadDelegate(downloader: self)
        session = URLSession(configuration: config, delegate: delegateHandler, delegateQueue: nil)

        if let resumeData {
            self.resumeData = nil
            log("ModelDownloader: resuming download for \(model.id)")
            downloadTask = session?.downloadTask(withResumeData: resumeData)
        } else {
            log("ModelDownloader: starting download for \(model.id) from \(model.downloadURL)")
            downloadTask = session?.downloadTask(with: model.downloadURL)
        }

        downloadTask?.resume()
    }

    /// Cancel the active download. Resume data is saved if available.
    public func cancel() {
        guard state == .downloading else { return }
        log("ModelDownloader: cancelling download")
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                self?.resumeData = data
            }
        })
        // State will be updated in the delegate's didCompleteWithError handler.
    }

    /// Whether this downloader has resume data from a previous cancelled download.
    public var canResume: Bool { resumeData != nil }

    /// Clear resume data (e.g. when the model or URL changes).
    public func clearResumeData() { resumeData = nil }

    // MARK: - Internal handlers (called from delegate via Task { @MainActor })

    fileprivate func handleProgress(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpected: Int64) {
        guard state == .downloading else { return }
        downloadedBytes = totalBytesWritten
        if totalBytesExpected > 0 {
            totalBytes = totalBytesExpected
        }

        // Speed calculation: keep samples from the last 2 seconds.
        let now = Date()
        speedSamples.append((date: now, bytes: totalBytesWritten))
        speedSamples.removeAll { now.timeIntervalSince($0.date) > 2.0 }
        if let first = speedSamples.first, speedSamples.count > 1 {
            let dt = now.timeIntervalSince(first.date)
            if dt > 0 {
                bytesPerSecond = Double(totalBytesWritten - first.bytes) / dt
            }
        }

        // Throttle callback to ≥ 0.2s.
        if now.timeIntervalSince(lastProgressCallbackDate) >= 0.2 {
            lastProgressCallbackDate = now
            onProgress?(totalBytesWritten, totalBytes)
        }
    }

    fileprivate func handleFinishedDownload(temporaryURL: URL) {
        guard let dest = destinationURL else { return }

        do {
            // Remove existing file if present (e.g. partial/corrupt from prior attempt).
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            // Atomic move from the temporary location.
            try FileManager.default.moveItem(at: temporaryURL, to: dest)

            log("ModelDownloader: saved to \(dest.path)")
            state = .completed
            resumeData = nil
            onDone?()
        } catch {
            applyError("Failed to save model: \(error.localizedDescription)")
        }

        session?.invalidateAndCancel()
        session = nil
    }

    fileprivate func handleError(_ error: Error) {
        let nsError = error as NSError
        // URLSession cancellation: domain=NSURLErrorDomain, code=-999
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            state = .cancelled
            log("ModelDownloader: cancelled")
            onCancelled?()
        } else {
            // Extract resume data from the error if available.
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeData = data
            }
            applyError(error.localizedDescription)
        }

        session?.invalidateAndCancel()
        session = nil
    }

    private func applyError(_ message: String) {
        log("ModelDownloader: error — \(message)")
        state = .failed(message)
        onError?(message)
    }
}

// MARK: - URLSession Delegate

/// Separate NSObject delegate so `ModelDownloader` can be `@MainActor` while the
/// session callbacks arrive on an arbitrary queue.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let downloader: ModelDownloader

    init(downloader: ModelDownloader) {
        self.downloader = downloader
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let dl = downloader
        Task { @MainActor in
            dl.handleProgress(
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy the temp file to a safe location immediately — URLSession deletes
        // the temp file as soon as this callback returns.
        let fm = FileManager.default
        let safeTmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf.tmp")
        do {
            try fm.moveItem(at: location, to: safeTmp)
            let dl = downloader
            Task { @MainActor in
                dl.handleFinishedDownload(temporaryURL: safeTmp)
            }
        } catch {
            let dl = downloader
            Task { @MainActor in
                dl.handleError(error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let dl = downloader
            Task { @MainActor in
                dl.handleError(error)
            }
        }
    }
}
