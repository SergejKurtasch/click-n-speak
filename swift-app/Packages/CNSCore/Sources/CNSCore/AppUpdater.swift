import AppKit
import Foundation

public enum AppUpdaterError: LocalizedError, Sendable, Equatable {
    case invalidHTTPResponse
    case archiveTooLarge
    case archiveSizeMismatch
    case archiveChecksumMismatch
    case insufficientDiskSpace
    case mountFailed
    case archiveContainsUnexpectedApplications
    case stagedCandidateMissing
    case candidateIdentityMissing
    case invalidLaunchAcknowledgement
    case helperMissing
    case helperNotReady
    case unsafePath
    case downloadInProgress
    case installationInProgress
    case installationHandleMismatch
    case helperDidNotExit

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse: "The update download returned an invalid response"
        case .archiveTooLarge: "The update archive exceeded the allowed size"
        case .archiveSizeMismatch: "The update archive size does not match its manifest"
        case .archiveChecksumMismatch: "The update archive checksum does not match its manifest"
        case .insufficientDiskSpace: "There is not enough disk space to stage the update"
        case .mountFailed: "The update disk image could not be mounted"
        case .archiveContainsUnexpectedApplications: "The update image must contain exactly one application"
        case .stagedCandidateMissing: "The validated update candidate is missing"
        case .candidateIdentityMissing: "The update candidate has no version or build identity"
        case .invalidLaunchAcknowledgement: "The update launch acknowledgement is invalid"
        case .helperMissing: "The signed update helper is missing from the application bundle"
        case .helperNotReady: "The update helper exited before it became ready"
        case .unsafePath: "The update attempted to use a path outside its controlled directory"
        case .downloadInProgress: "An application update download is already in progress"
        case .installationInProgress: "An application update installation is already in progress"
        case .installationHandleMismatch: "The active update installation does not match this request"
        case .helperDidNotExit: "The update helper did not exit after cancellation"
        }
    }
}

public protocol UpdateArchiveDownloading: Sendable {
    func download(
        from source: URL,
        to destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

private final class BoundedUpdateDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let handle: FileHandle
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var terminalError: Error?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var lastProgressTime: TimeInterval = 0
    private var cancelledByCaller = false
    private var finished = false

    init(
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.progress = progress
        try Data().write(to: destination, options: [.atomic])
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func run(task: URLSessionDataTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.task = task
                    return cancelledByCaller
                }
                if shouldCancel {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.lock.withLock { () -> URLSessionDataTask? in
                self.cancelledByCaller = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            lock.withLock { terminalError = AppUpdaterError.invalidHTTPResponse }
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= maximumBytes else {
            lock.withLock { terminalError = AppUpdaterError.archiveTooLarge }
            completionHandler(.cancel)
            return
        }
        lock.withLock { expected = http.expectedContentLength }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var reportedProgress: Double?
        var shouldCancel = false
        lock.withLock {
            guard terminalError == nil, !finished else { return }
            guard maximumBytes >= received,
                  Int64(data.count) <= maximumBytes - received else {
                terminalError = AppUpdaterError.archiveTooLarge
                shouldCancel = true
                return
            }
            do {
                try handle.write(contentsOf: data)
                received += Int64(data.count)
                let now = Date.timeIntervalSinceReferenceDate
                if now - lastProgressTime >= 0.1 {
                    lastProgressTime = now
                    let denominator = expected > 0 ? expected : maximumBytes
                    if denominator > 0 {
                        reportedProgress = min(1, Double(received) / Double(denominator))
                    }
                }
            } catch {
                terminalError = error
                shouldCancel = true
            }
        }
        if let reportedProgress { progress(reportedProgress) }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let completion = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            guard !finished else { return (nil, nil) }
            finished = true
            var finalError = terminalError
            if finalError == nil, cancelledByCaller {
                finalError = CancellationError()
            } else if finalError == nil {
                finalError = error
            }
            if finalError == nil {
                do { try handle.synchronize() } catch { finalError = error }
            }
            try? handle.close()
            if finalError != nil { try? FileManager.default.removeItem(at: destination) }
            return (continuation, finalError)
        }
        guard let continuation = completion.0 else { return }
        if let error = completion.1 {
            continuation.resume(throwing: error)
        } else {
            progress(1)
            continuation.resume()
        }
    }
}

public final class URLSessionUpdateArchiveDownloader: UpdateArchiveDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    public func download(
        from source: URL,
        to destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        progress(0)
        var request = URLRequest(url: source)
        request.timeoutInterval = 4 * 3600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let delegate = try BoundedUpdateDownloadDelegate(
            destination: destination,
            maximumBytes: maximumBytes,
            progress: progress
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        do {
            try await delegate.run(task: task)
            session.finishTasksAndInvalidate()
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }
}

public protocol DiskImageMounting: Sendable {
    func mount(image: URL, at mountPoint: URL) throws
    func unmount(_ mountPoint: URL)
}

public struct SystemDiskImageMounter: DiskImageMounting {
    public init() {}

    public func mount(image: URL, at mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", "-nobrowse", "-readonly", "-noautoopen",
            "-mountpoint", mountPoint.path, image.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdaterError.mountFailed }
    }

    public func unmount(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

private struct StagedUpdate: Sendable {
    let operationID: UUID
    let update: AppUpdate
    let sessionDirectory: URL
    let candidateURL: URL
}

/// Coordinates update download and verification in the injected Application
/// Support directory. Installation is delegated to the separately signed
/// helper only after the user explicitly chooses Restart.
public actor AppUpdater {
    public static let shared = AppUpdater(paths: .resolveDefault())

    private let paths: Paths
    private let archiveDownloader: any UpdateArchiveDownloading
    private let mounter: any DiskImageMounting
    private let verifier: any UpdateCandidateVerifying
    private let diskCapacity: @Sendable (URL) -> Int64
    private let currentVersion: @Sendable () -> String
    private let targetApplicationURL: URL
    private let helperExecutableURL: URL
    private var staged: StagedUpdate?

    private struct ActiveInstallation {
        let handle: UpdateInstallationHandle
        let process: Process
        let preparedCandidate: URL
        let backup: URL
        let record: URL
    }
    private var activeInstallation: ActiveInstallation?
    private var installationPreparationOperationID: UUID?

    private var operationGeneration = 0
    private var activeDownloadOperationID: UUID?

    public init(
        paths: Paths,
        archiveDownloader: any UpdateArchiveDownloading = URLSessionUpdateArchiveDownloader(),
        mounter: any DiskImageMounting = SystemDiskImageMounter(),
        verifier: any UpdateCandidateVerifying = SystemUpdateCandidateVerifier(),
        diskCapacity: @escaping @Sendable (URL) -> Int64 = ModelManager.availableDiskCapacity,
        currentVersion: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        },
        targetApplicationURL: URL = Bundle.main.bundleURL,
        helperExecutableURL: URL? = nil
    ) {
        self.paths = paths
        self.archiveDownloader = archiveDownloader
        self.mounter = mounter
        self.verifier = verifier
        self.diskCapacity = diskCapacity
        self.currentVersion = currentVersion
        self.targetApplicationURL = targetApplicationURL
        self.helperExecutableURL = helperExecutableURL
            ?? targetApplicationURL.appendingPathComponent("Contents/MacOS/CNSUpdateHelper")
    }


    @discardableResult
    public func downloadAndStage(
        update: AppUpdate,
        operationID: UUID,
        progress: @escaping @Sendable (AppUpdateProgress) -> Void
    ) async throws -> StagedUpdateHandle {
        try Task.checkCancellation()
        guard activeDownloadOperationID == nil else { throw AppUpdaterError.downloadInProgress }
        activeDownloadOperationID = operationID
        defer {
            if activeDownloadOperationID == operationID { activeDownloadOperationID = nil }
        }
        operationGeneration += 1
        let generation = operationGeneration
        try paths.ensureUpdatesDirectory()
        let required = update.archiveSize * 2 + 256 * 1_024 * 1_024
        guard diskCapacity(paths.updatesDirectory) >= required else {
            throw AppUpdaterError.insufficientDiskSpace
        }

        let sessionDirectory = paths.updatesDirectory.appendingPathComponent(
            "staging-\(operationID.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        do {
            let partialArchive = sessionDirectory.appendingPathComponent("update.dmg.partial")
            progress(AppUpdateProgress(stage: .downloading, fraction: 0))
            try await archiveDownloader.download(
                from: update.downloadURL,
                to: partialArchive,
                maximumBytes: update.archiveSize,
                progress: { fraction in progress(AppUpdateProgress(stage: .downloading, fraction: fraction)) }
            )
            try ensureCurrent(generation)
            
            progress(AppUpdateProgress(stage: .verifyingArchive, fraction: nil))
            let size = Int64((try partialArchive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            guard size == update.archiveSize else { throw AppUpdaterError.archiveSizeMismatch }
            guard try await ArtifactIntegrity.sha256(of: partialArchive) == update.sha256 else {
                throw AppUpdaterError.archiveChecksumMismatch
            }
            try ensureCurrent(generation)
            
            progress(AppUpdateProgress(stage: .staging, fraction: nil))
            let archive = sessionDirectory.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: partialArchive, to: archive)

            let mountPoint = sessionDirectory.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) {
                try self.mounter.mount(image: archive, at: mountPoint)
            }.value
            defer { mounter.unmount(mountPoint) }

            let contents = try FileManager.default.contentsOfDirectory(
                at: mountPoint,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let applications = contents.filter { $0.pathExtension.lowercased() == "app" }
            guard applications.count == 1, let sourceApplication = applications.first else {
                throw AppUpdaterError.archiveContainsUnexpectedApplications
            }
            let candidate = sessionDirectory.appendingPathComponent("Click-n-speak.app", isDirectory: true)
            try FileManager.default.copyItem(at: sourceApplication, to: candidate)
            try ensureCurrent(generation)
            
            progress(AppUpdateProgress(stage: .verifyingCandidate, fraction: nil))
            try await verifier.verify(
                candidateURL: candidate,
                policy: CandidateVerificationPolicy(
                    bundleIdentifier: update.bundleIdentifier,
                    teamIdentifier: update.teamIdentifier,
                    currentVersion: currentVersion(),
                    architecture: .current
                )
            )
            try ensureCurrent(generation)
            try? FileManager.default.removeItem(at: archive)
            staged = StagedUpdate(
                operationID: operationID,
                update: update,
                sessionDirectory: sessionDirectory,
                candidateURL: candidate
            )
            progress(AppUpdateProgress(stage: .ready, fraction: 1.0))
            return StagedUpdateHandle(operationID: operationID, version: update.version)
        } catch {
            try? FileManager.default.removeItem(at: sessionDirectory)
            if staged?.sessionDirectory == sessionDirectory { staged = nil }
            throw error
        }
    }


    public func cancelPendingInstallation(handle: UpdateInstallationHandle) async throws {
        guard let installation = activeInstallation, installation.handle == handle else {
            throw AppUpdaterError.installationHandleMismatch
        }
        let process = installation.process
        if process.isRunning {
            process.terminate()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw AppUpdaterError.helperDidNotExit }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !FileManager.default.fileExists(atPath: installation.backup.path) else {
            throw AppUpdaterError.unsafePath
        }
        try markCancelledTransaction(installation)
        if FileManager.default.fileExists(atPath: installation.preparedCandidate.path) {
            try FileManager.default.removeItem(at: installation.preparedCandidate)
        }
        activeInstallation = nil
    }

    public func pendingInstallationHandle() -> UpdateInstallationHandle? {
        activeInstallation?.handle
    }

    public func isPendingInstallationReady(handle: UpdateInstallationHandle) -> Bool {
        guard let installation = activeInstallation, installation.handle == handle else { return false }
        guard installation.process.isRunning,
              let record = try? FileUpdateTransactionStore().load(from: installation.record) else {
            return false
        }
        return record.transactionID == handle.transactionID.uuidString
            && (record.phase == .prepared || record.phase == .installing)
    }

    private func markCancelledTransaction(_ installation: ActiveInstallation) throws {
        guard FileManager.default.fileExists(atPath: installation.record.path) else { return }
        let store = FileUpdateTransactionStore()
        var record = try store.load(from: installation.record)
        guard record.transactionID == installation.handle.transactionID.uuidString,
              record.phase == .prepared || record.phase == .installing || record.phase == .rolledBack else {
            throw AppUpdaterError.unsafePath
        }
        if record.phase != .rolledBack {
            record.phase = .rolledBack
            record.failure = .parentDidNotExit
            try store.save(record, to: installation.record)
        }
    }

    public func cancelAndCleanUp(operationID: UUID) {
        guard activeDownloadOperationID == operationID || staged?.operationID == operationID else {
            return
        }
        if staged?.operationID == operationID {
            if let staged {
                try? FileManager.default.removeItem(at: staged.sessionDirectory)
            }
            staged = nil
        }
        if activeDownloadOperationID == operationID {
            operationGeneration += 1
        }
    }

    /// Copy the validated candidate beside the installed application, verify the
    /// copy again, then launch the signed helper. No hard-coded `/Applications`
    /// path is used.
    public func beginInstallation(handle: StagedUpdateHandle) async throws -> UpdateInstallationHandle {
        guard activeInstallation == nil, installationPreparationOperationID == nil else {
            throw AppUpdaterError.installationInProgress
        }
        guard let staged,
              staged.operationID == handle.operationID,
              staged.update.version == handle.version,
              FileManager.default.fileExists(atPath: staged.candidateURL.path) else {
            throw AppUpdaterError.stagedCandidateMissing
        }
        installationPreparationOperationID = handle.operationID
        defer { installationPreparationOperationID = nil }
        let target = targetApplicationURL.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        let transactionID = UUID()
        let preparedCandidate = parent.appendingPathComponent(
            ".Click-n-speak.update-\(transactionID.uuidString).app",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".Click-n-speak.backup-\(transactionID.uuidString).app",
            isDirectory: true
        )
        var launchedProcess: Process?
        var launchedRecord: URL?
        do {
            try FileManager.default.copyItem(at: staged.candidateURL, to: preparedCandidate)
            try await verifier.verify(
                candidateURL: preparedCandidate,
                policy: CandidateVerificationPolicy(
                    bundleIdentifier: staged.update.bundleIdentifier,
                    teamIdentifier: staged.update.teamIdentifier,
                    currentVersion: currentVersion(),
                    architecture: .current
                )
            )
            guard FileManager.default.isExecutableFile(atPath: helperExecutableURL.path) else {
                throw AppUpdaterError.helperMissing
            }
            let token = UUID().uuidString
            guard let candidateBundle = Bundle(url: preparedCandidate),
                  let candidateVersion = candidateBundle.object(
                      forInfoDictionaryKey: "CFBundleShortVersionString"
                  ) as? String,
                  let candidateBuild = candidateBundle.object(
                      forInfoDictionaryKey: "CFBundleVersion"
                  ) as? String,
                  let candidateExecutable = candidateBundle.executableURL,
                  !candidateVersion.isEmpty,
                  !candidateBuild.isEmpty else {
                throw AppUpdaterError.candidateIdentityMissing
            }
            let candidateExecutableSHA256 = try await ArtifactIntegrity.sha256(of: candidateExecutable)
            let ack = paths.updatesDirectory.appendingPathComponent("ack-\(transactionID.uuidString)")
            let record = paths.updatesDirectory.appendingPathComponent("transaction-\(transactionID.uuidString).json")
            let process = Process()
            process.executableURL = helperExecutableURL
            process.arguments = [
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--staged", preparedCandidate.path,
            "--target", target.path,
            "--backup", backup.path,
            "--token", token,
            "--transaction-id", transactionID.uuidString,
            "--candidate-version", candidateVersion,
            "--candidate-build", candidateBuild,
            "--candidate-sha256", staged.update.sha256,
            "--candidate-executable-sha256", candidateExecutableSHA256,
            "--ack", ack.path,
            "--record", record.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            launchedProcess = process
            launchedRecord = record
            try await waitForHelperReadiness(
                process: process,
                record: record,
                transactionID: transactionID
            )
            let outHandle = UpdateInstallationHandle(transactionID: transactionID, operationID: handle.operationID)
            self.activeInstallation = ActiveInstallation(
                handle: outHandle,
                process: process,
                preparedCandidate: preparedCandidate,
                backup: backup,
                record: record
            )
            return outHandle
        } catch {
            if let launchedProcess, let launchedRecord {
                let outHandle = UpdateInstallationHandle(transactionID: transactionID, operationID: handle.operationID)
                let installation = ActiveInstallation(
                    handle: outHandle,
                    process: launchedProcess,
                    preparedCandidate: preparedCandidate,
                    backup: backup,
                    record: launchedRecord
                )
                if launchedProcess.isRunning {
                    launchedProcess.terminate()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while launchedProcess.isRunning, ContinuousClock.now < deadline {
                        await Task.detached {
                            try? await Task.sleep(for: .milliseconds(100))
                        }.value
                    }
                    if launchedProcess.isRunning {
                        activeInstallation = installation
                        throw AppUpdaterError.helperDidNotExit
                    }
                }
                do {
                    guard !FileManager.default.fileExists(atPath: backup.path) else {
                        throw AppUpdaterError.unsafePath
                    }
                    try markCancelledTransaction(installation)
                } catch {
                    activeInstallation = installation
                    throw error
                }
            }
            if FileManager.default.fileExists(atPath: preparedCandidate.path) {
                try? FileManager.default.removeItem(at: preparedCandidate)
            }
            throw error
        }
    }

    private func waitForHelperReadiness(
        process: Process,
        record: URL,
        transactionID: UUID
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            guard process.isRunning else { throw AppUpdaterError.helperNotReady }
            if FileManager.default.fileExists(atPath: record.path),
               let transaction = try? FileUpdateTransactionStore().load(from: record),
               transaction.transactionID == transactionID.uuidString,
               transaction.phase == .prepared || transaction.phase == .installing {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AppUpdaterError.helperNotReady
    }


    public static func hasUpdateLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        argument("--update-validation-token", in: arguments) != nil
    }

    /// Called only after the replacement reaches a policy-approved launch
    /// boundary. The acknowledgement binds candidate identity and exact PID.
    public static func acknowledgeSuccessfulLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        paths: Paths,
        status: UpdateLaunchStatus,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        bundle: Bundle = .main
    ) async throws {
        guard let token = argument("--update-validation-token", in: arguments) else { return }
        guard UUID(uuidString: token) != nil,
              let ackPath = argument("--update-ack-path", in: arguments) else {
            throw AppUpdaterError.invalidLaunchAcknowledgement
        }
        let ackURL = URL(fileURLWithPath: ackPath).standardizedFileURL
        let allowedPrefix = paths.updatesDirectory.standardizedFileURL.path + "/"
        guard ackURL.path.hasPrefix(allowedPrefix) else { throw AppUpdaterError.unsafePath }
        let version = argument("--update-candidate-version", in: arguments)
        let build = argument("--update-candidate-build", in: arguments)
        let archiveSHA256 = argument("--update-candidate-sha256", in: arguments)
        let executableSHA256 = argument("--update-candidate-executable-sha256", in: arguments)
        let identityArguments = [version, build, archiveSHA256, executableSHA256]
        if identityArguments.allSatisfy({ $0 == nil }) {
            try paths.ensureUpdatesDirectory()
            try AtomicFile.writeData(Data(token.utf8), to: ackURL)
            return
        }
        guard let version,
              let build,
              let archiveSHA256,
              let executableSHA256,
              archiveSHA256.count == 64,
              archiveSHA256.allSatisfy(\.isHexDigit),
              executableSHA256.count == 64,
              executableSHA256.allSatisfy(\.isHexDigit),
              let executableURL = bundle.executableURL else {
            throw AppUpdaterError.invalidLaunchAcknowledgement
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == build else {
            throw AppUpdaterError.unsafePath
        }
        guard try await ArtifactIntegrity.sha256(of: executableURL) == executableSHA256.lowercased() else {
            throw AppUpdaterError.unsafePath
        }
        try paths.ensureUpdatesDirectory()
        let acknowledgement = UpdateLaunchAcknowledgement(
            token: token,
            candidate: UpdateCandidateIdentity(
                version: version,
                build: build,
                archiveSHA256: archiveSHA256,
                executableSHA256: executableSHA256
            ),
            processID: processID,
            status: status
        )
        try AtomicFile.writeData(try JSONEncoder().encode(acknowledgement), to: ackURL)
    }

    @discardableResult
    public static func recoverInterruptedTransactions(
        paths: Paths,
        status: UpdateLaunchStatus,
        currentApplication: URL = Bundle.main.bundleURL,
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "",
        currentBuild: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "",
        currentExecutableSHA256: String? = nil,
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        store: any UpdateTransactionStoring = FileUpdateTransactionStore(),
        files: any UpdateFileOperating = SystemUpdateFileOperator()
    ) async throws -> [UpdateRecoveryOutcome] {
        guard FileManager.default.fileExists(atPath: paths.updatesDirectory.path) else { return [] }
        let executableSHA256: String
        if let currentExecutableSHA256 {
            executableSHA256 = currentExecutableSHA256.lowercased()
        } else {
            guard let bundle = Bundle(url: currentApplication),
                  let executableURL = bundle.executableURL else {
                throw AppUpdaterError.candidateIdentityMissing
            }
            executableSHA256 = try await ArtifactIntegrity.sha256(of: executableURL)
        }
        let records = try FileManager.default.contentsOfDirectory(
            at: paths.updatesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix("transaction-") && $0.pathExtension == "json"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        let recovery = UpdateTransactionRecovery(store: store, files: files)
        return try records.map { recordURL in
            let record = try store.load(from: recordURL)
            guard let candidate = record.candidate else { return .deferred }
            let currentCandidate = UpdateCandidateIdentity(
                version: currentVersion,
                build: currentBuild,
                archiveSHA256: candidate.archiveSHA256,
                executableSHA256: executableSHA256
            )
            return try recovery.recover(
                recordURL: recordURL,
                currentApplication: currentApplication,
                currentCandidate: currentCandidate,
                currentProcessID: currentProcessID,
                status: status
            )
        }
    }

    private func ensureCurrent(_ generation: Int) throws {
        guard generation == operationGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
