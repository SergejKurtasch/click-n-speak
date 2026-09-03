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
    case helperMissing
    case unsafePath

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
        case .helperMissing: "The signed update helper is missing from the application bundle"
        case .unsafePath: "The update attempted to use a path outside its controlled directory"
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

public struct URLSessionUpdateArchiveDownloader: UpdateArchiveDownloading {
    public init() {}

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
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppUpdaterError.invalidHTTPResponse
        }
        if http.expectedContentLength > maximumBytes {
            throw AppUpdaterError.archiveTooLarge
        }
        let size = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        guard size >= 0, size <= maximumBytes else { throw AppUpdaterError.archiveTooLarge }
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
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
    private var staged: StagedUpdate?
    private var operationGeneration = 0

    public init(
        paths: Paths,
        archiveDownloader: any UpdateArchiveDownloading = URLSessionUpdateArchiveDownloader(),
        mounter: any DiskImageMounting = SystemDiskImageMounter(),
        verifier: any UpdateCandidateVerifying = SystemUpdateCandidateVerifier(),
        diskCapacity: @escaping @Sendable (URL) -> Int64 = ModelManager.availableDiskCapacity,
        currentVersion: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        }
    ) {
        self.paths = paths
        self.archiveDownloader = archiveDownloader
        self.mounter = mounter
        self.verifier = verifier
        self.diskCapacity = diskCapacity
        self.currentVersion = currentVersion
    }

    @discardableResult
    public func downloadAndStage(
        update: AppUpdate,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        operationGeneration += 1
        let generation = operationGeneration
        try paths.ensureUpdatesDirectory()
        let required = update.archiveSize * 2 + 256 * 1_024 * 1_024
        guard diskCapacity(paths.updatesDirectory) >= required else {
            throw AppUpdaterError.insufficientDiskSpace
        }

        let sessionDirectory = paths.updatesDirectory.appendingPathComponent(
            "staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        do {
            let partialArchive = sessionDirectory.appendingPathComponent("update.dmg.partial")
            try await archiveDownloader.download(
                from: update.downloadURL,
                to: partialArchive,
                maximumBytes: update.archiveSize,
                progress: progress
            )
            try ensureCurrent(generation)
            let size = Int64((try partialArchive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            guard size == update.archiveSize else { throw AppUpdaterError.archiveSizeMismatch }
            guard try await ArtifactIntegrity.sha256(of: partialArchive) == update.sha256 else {
                throw AppUpdaterError.archiveChecksumMismatch
            }
            try ensureCurrent(generation)
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
                update: update,
                sessionDirectory: sessionDirectory,
                candidateURL: candidate
            )
            progress(1)
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: sessionDirectory)
            if staged?.sessionDirectory == sessionDirectory { staged = nil }
            throw error
        }
    }

    public func cancelAndCleanUp() {
        operationGeneration += 1
        if let staged {
            try? FileManager.default.removeItem(at: staged.sessionDirectory)
        }
        staged = nil
    }

    /// Copy the validated candidate beside the installed application, verify the
    /// copy again, then launch the signed helper. No hard-coded `/Applications`
    /// path is used.
    public func swapAndRelaunch() async throws {
        guard let staged,
              FileManager.default.fileExists(atPath: staged.candidateURL.path) else {
            throw AppUpdaterError.stagedCandidateMissing
        }
        let target = Bundle.main.bundleURL.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        let transactionID = UUID().uuidString
        let preparedCandidate = parent.appendingPathComponent(
            ".Click-n-speak.update-\(transactionID).app",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".Click-n-speak.backup-\(transactionID).app",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: staged.candidateURL, to: preparedCandidate)
        do {
            try await verifier.verify(
                candidateURL: preparedCandidate,
                policy: CandidateVerificationPolicy(
                    bundleIdentifier: staged.update.bundleIdentifier,
                    teamIdentifier: staged.update.teamIdentifier,
                    currentVersion: currentVersion(),
                    architecture: .current
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: preparedCandidate)
            throw error
        }

        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/CNSUpdateHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            try? FileManager.default.removeItem(at: preparedCandidate)
            throw AppUpdaterError.helperMissing
        }
        let token = UUID().uuidString
        let ack = paths.updatesDirectory.appendingPathComponent("ack-\(transactionID)")
        let record = paths.updatesDirectory.appendingPathComponent("transaction-\(transactionID).json")
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--staged", preparedCandidate.path,
            "--target", target.path,
            "--backup", backup.path,
            "--token", token,
            "--ack", ack.path,
            "--record", record.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        await MainActor.run { NSApp.terminate(nil) }
    }

    /// Called by the replacement after its runtime reached the ready/degraded
    /// launch boundary. The helper only deletes the backup after this token.
    public static func acknowledgeSuccessfulLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        paths: Paths
    ) throws {
        guard let token = argument("--update-validation-token", in: arguments),
              let ackPath = argument("--update-ack-path", in: arguments) else { return }
        let ackURL = URL(fileURLWithPath: ackPath).standardizedFileURL
        let allowedPrefix = paths.updatesDirectory.standardizedFileURL.path + "/"
        guard ackURL.path.hasPrefix(allowedPrefix) else { throw AppUpdaterError.unsafePath }
        try paths.ensureUpdatesDirectory()
        try Data(token.utf8).write(to: ackURL, options: [.atomic])
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
