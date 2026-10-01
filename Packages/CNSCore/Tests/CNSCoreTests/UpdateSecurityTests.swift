import CryptoKit
import Foundation
import XCTest
@testable import CNSCore

private let allowedUpdateEntitlements: Set<String> = [
    "com.apple.security.automation.apple-events",
    "com.apple.security.device.audio-input",
    "com.apple.security.network.client",
]

private func validCandidateMetadata() -> CandidateBundleMetadata {
    CandidateBundleMetadata(
        bundleIdentifier: "com.sergej.clicknspeak",
        teamIdentifier: "ABCDE12345",
        version: "2.0.0",
        architectures: [.arm64],
        signatureValid: true,
        hardenedRuntime: true,
        notarized: true,
        entitlements: allowedUpdateEntitlements,
        hasUnexpectedHelpers: false
    )
}

private let candidatePolicy = CandidateVerificationPolicy(
    bundleIdentifier: "com.sergej.clicknspeak",
    teamIdentifier: "ABCDE12345",
    currentVersion: "1.0.0",
    architecture: .arm64
)

final class CandidateMetadataValidatorTests: XCTestCase {
    func testValidCandidatePasses() throws {
        try CandidateMetadataValidator.validate(validCandidateMetadata(), policy: candidatePolicy)
    }

    func testCandidateFailureMatrix() {
        let valid = validCandidateMetadata()
        let cases: [(String, CandidateBundleMetadata, CandidateVerificationError)] = [
            ("bundle", metadata(valid, bundleIdentifier: "com.example.bad"), .wrongBundleIdentifier),
            ("team", metadata(valid, teamIdentifier: "BADTEAM"), .wrongTeamIdentifier),
            ("signature", metadata(valid, signatureValid: false), .invalidSignature),
            ("runtime", metadata(valid, hardenedRuntime: false), .hardenedRuntimeMissing),
            ("notarization", metadata(valid, notarized: false), .notarizationMissing),
            ("architecture", metadata(valid, architectures: [.x86_64]), .unsupportedArchitecture),
            ("version", metadata(valid, version: "1.0.0"), .versionNotNewer),
            (
                "entitlement",
                metadata(valid, entitlements: allowedUpdateEntitlements.union(["com.apple.security.cs.disable-library-validation"])),
                .unexpectedEntitlements(["com.apple.security.cs.disable-library-validation"])
            ),
            ("helper", metadata(valid, hasUnexpectedHelpers: true), .unexpectedHelperPayload),
        ]
        for (name, candidate, expected) in cases {
            XCTAssertThrowsError(try CandidateMetadataValidator.validate(candidate, policy: candidatePolicy)) { error in
                XCTAssertEqual(error as? CandidateVerificationError, expected, name)
            }
        }
    }

    private func metadata(
        _ base: CandidateBundleMetadata,
        bundleIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        version: String? = nil,
        architectures: Set<UpdateArchitecture>? = nil,
        signatureValid: Bool? = nil,
        hardenedRuntime: Bool? = nil,
        notarized: Bool? = nil,
        entitlements: Set<String>? = nil,
        hasUnexpectedHelpers: Bool? = nil
    ) -> CandidateBundleMetadata {
        CandidateBundleMetadata(
            bundleIdentifier: bundleIdentifier ?? base.bundleIdentifier,
            teamIdentifier: teamIdentifier ?? base.teamIdentifier,
            version: version ?? base.version,
            architectures: architectures ?? base.architectures,
            signatureValid: signatureValid ?? base.signatureValid,
            hardenedRuntime: hardenedRuntime ?? base.hardenedRuntime,
            notarized: notarized ?? base.notarized,
            entitlements: entitlements ?? base.entitlements,
            hasUnexpectedHelpers: hasUnexpectedHelpers ?? base.hasUnexpectedHelpers
        )
    }
}

private final class FaultingFileOperator: UpdateFileOperating, @unchecked Sendable {
    private let system = SystemUpdateFileOperator()
    private let failOnMove: Int?
    private let failOnReplace: Int?
    private var moveCount = 0
    private var replaceCount = 0

    init(failOnMove: Int? = nil, failOnReplace: Int? = nil) {
        self.failOnMove = failOnMove
        self.failOnReplace = failOnReplace
    }

    func fileExists(at url: URL) -> Bool { system.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try system.createDirectory(at: url) }
    func replaceItem(at target: URL, with staged: URL, backup: URL) throws {
        replaceCount += 1
        if replaceCount == failOnReplace { throw CocoaError(.fileWriteUnknown) }
        try system.replaceItem(at: target, with: staged, backup: backup)
    }
    func copyItem(at source: URL, to destination: URL) throws {
        try system.copyItem(at: source, to: destination)
    }
    func removeItem(at url: URL) throws { try system.removeItem(at: url) }
    func moveItem(at source: URL, to destination: URL) throws {
        moveCount += 1
        if moveCount == failOnMove { throw CocoaError(.fileWriteUnknown) }
        try system.moveItem(at: source, to: destination)
    }
}

final class RecoverableAppSwapTests: XCTestCase {
    func testSuccessKeepsBackupUntilAcknowledgement() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let swap = RecoverableAppSwap()
        try swap.install(staged: fixture.staged, target: fixture.target, backup: fixture.backup)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.backup, encoding: .utf8), "old")
        try swap.finalize(backup: fixture.backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
    }

    func testAtomicReplacementFailureDoesNotChangeTarget() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let swap = RecoverableAppSwap(files: FaultingFileOperator(failOnReplace: 1))
        XCTAssertThrowsError(try swap.install(staged: fixture.staged, target: fixture.target, backup: fixture.backup))
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
    }

    func testExplicitRollbackRestoresBackup() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let swap = RecoverableAppSwap()
        try swap.install(staged: fixture.staged, target: fixture.target, backup: fixture.backup)
        try swap.rollback(
            target: fixture.target,
            backup: fixture.backup,
            failedCandidate: fixture.failedCandidate
        )
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: fixture.failedCandidate, encoding: .utf8), "new")
    }

    func testRollbackWithoutBackupLeavesTargetUntouched() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let swap = RecoverableAppSwap()

        XCTAssertThrowsError(
            try swap.rollback(
                target: fixture.target,
                backup: fixture.backup,
                failedCandidate: fixture.failedCandidate
            )
        )
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.failedCandidate.path))
    }

    func testRollbackRestoreFailureReturnsCandidateToTarget() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try RecoverableAppSwap().install(
            staged: fixture.staged,
            target: fixture.target,
            backup: fixture.backup
        )
        let swap = RecoverableAppSwap(files: FaultingFileOperator(failOnReplace: 1))

        XCTAssertThrowsError(
            try swap.rollback(
                target: fixture.target,
                backup: fixture.backup,
                failedCandidate: fixture.failedCandidate
            )
        )
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.backup, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.failedCandidate.path))
    }

    func testRollbackResumesAfterCandidateWasAlreadyMovedAside() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try RecoverableAppSwap().install(
            staged: fixture.staged,
            target: fixture.target,
            backup: fixture.backup
        )
        try FileManager.default.moveItem(at: fixture.target, to: fixture.failedCandidate)

        try RecoverableAppSwap().rollback(
            target: fixture.target,
            backup: fixture.backup,
            failedCandidate: fixture.failedCandidate
        )

        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: fixture.failedCandidate, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
    }

    private func makeSwapFixture() throws -> (
        root: URL,
        staged: URL,
        target: URL,
        backup: URL,
        failedCandidate: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("staged.app")
        let target = root.appendingPathComponent("target.app")
        let backup = root.appendingPathComponent("backup.app")
        let failedCandidate = root.appendingPathComponent("failed-candidate.app")
        try "new".write(to: staged, atomically: true, encoding: .utf8)
        try "old".write(to: target, atomically: true, encoding: .utf8)
        return (root, staged, target, backup, failedCandidate)
    }
}

private struct FixtureArchiveDownloader: UpdateArchiveDownloading {
    let data: Data
    let error: Error?

    init(data: Data, error: Error? = nil) {
        self.data = data
        self.error = error
    }

    func download(
        from source: URL,
        to destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let error { throw error }
        try data.write(to: destination)
        progress(1)
    }
}

private struct FixtureMounter: DiskImageMounting {
    func mount(image: URL, at mountPoint: URL) throws {
        let app = mountPoint.appendingPathComponent("Click-n-speak.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("candidate".utf8).write(to: app.appendingPathComponent("marker"))
    }

    func unmount(_ mountPoint: URL) {}
}

private struct BundleFixtureMounter: DiskImageMounting {
    let bundle: URL

    func mount(image: URL, at mountPoint: URL) throws {
        try FileManager.default.copyItem(
            at: bundle,
            to: mountPoint.appendingPathComponent("Click-n-speak.app", isDirectory: true)
        )
    }

    func unmount(_ mountPoint: URL) {}
}

private struct AcceptingCandidateVerifier: UpdateCandidateVerifying {
    func verify(candidateURL: URL, policy: CandidateVerificationPolicy) async throws {}
}

private actor SuspendedCandidateVerifier: UpdateCandidateVerifying {
    private var verification: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func verify(candidateURL: URL, policy: CandidateVerificationPolicy) async throws {
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation in
            verification = continuation
        }
    }

    func waitUntilStarted() async {
        if verification != nil { return }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func release() {
        verification?.resume()
        verification = nil
    }
}

private final class StreamingUpdateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chunks: [Data] = []

    static func install(chunks: [Data]) {
        lock.withLock { self.chunks = chunks }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.lock.withLock({ Self.chunks }) {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AppUpdaterStagingTests: XCTestCase {
    func testArchiveDownloadWritesNetworkChunksWithoutPerByteProgress() async throws {
        let first = Data(repeating: 0x41, count: 4)
        let second = Data(repeating: 0x42, count: 4)
        StreamingUpdateURLProtocol.install(chunks: [first, second])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingUpdateURLProtocol.self]
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-stream-success-\(UUID().uuidString).dmg")
        let progressValues = LockedProgressValues()
        defer { try? FileManager.default.removeItem(at: destination) }

        try await URLSessionUpdateArchiveDownloader(configuration: configuration).download(
            from: URL(string: "https://example.invalid/update.dmg")!,
            to: destination,
            maximumBytes: 10,
            progress: { progressValues.append($0) }
        )

        XCTAssertEqual(try Data(contentsOf: destination), first + second)
        XCTAssertLessThanOrEqual(progressValues.values.count, 4)
        XCTAssertEqual(progressValues.values.last, 1)
    }

    func testArchiveDownloadStopsAtByteLimitAndRemovesPartialFile() async throws {
        StreamingUpdateURLProtocol.install(chunks: [
            Data(repeating: 0x41, count: 4),
            Data(repeating: 0x42, count: 4),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingUpdateURLProtocol.self]
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-stream-\(UUID().uuidString).dmg")
        defer {
            try? FileManager.default.removeItem(at: destination)
        }

        do {
            try await URLSessionUpdateArchiveDownloader(configuration: configuration).download(
                from: URL(string: "https://example.invalid/update.dmg")!,
                to: destination,
                maximumBytes: 6,
                progress: { _ in }
            )
            XCTFail("Expected archive size limit failure")
        } catch let error as AppUpdaterError {
            XCTAssertEqual(error, .archiveTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLaunchAcknowledgementContainsBoundCandidateAndExactProcess() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureUpdatesDirectory()
        let bundleURL = try makeBundle(version: "2.0.0", build: "200")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        guard let bundle = Bundle(url: bundleURL) else {
            XCTFail("Expected fixture bundle")
            return
        }
        let token = UUID().uuidString
        let sha256 = String(repeating: "a", count: 64)
        let executableSHA256 = try await ArtifactIntegrity.sha256(of: bundle.executableURL!)
        let acknowledgementURL = paths.updatesDirectory.appendingPathComponent("ack-fixture")

        try await AppUpdater.acknowledgeSuccessfulLaunch(
            arguments: [
                "Click-n-speak",
                "--update-validation-token", token,
                "--update-ack-path", acknowledgementURL.path,
                "--update-candidate-version", "2.0.0",
                "--update-candidate-build", "200",
                "--update-candidate-sha256", sha256,
                "--update-candidate-executable-sha256", executableSHA256,
            ],
            paths: paths,
            status: .ready,
            processID: 4242,
            bundle: bundle
        )

        let acknowledgement = try JSONDecoder().decode(
            UpdateLaunchAcknowledgement.self,
            from: Data(contentsOf: acknowledgementURL)
        )
        XCTAssertEqual(acknowledgement.token, token)
        XCTAssertEqual(
            acknowledgement.candidate,
            UpdateCandidateIdentity(
                version: "2.0.0",
                build: "200",
                archiveSHA256: sha256,
                executableSHA256: executableSHA256
            )
        )
        XCTAssertEqual(acknowledgement.processID, 4242)
        XCTAssertEqual(acknowledgement.status, .ready)
    }

    func testLegacyLaunchAcknowledgementWritesRawToken() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let token = UUID().uuidString
        let acknowledgementURL = paths.updatesDirectory.appendingPathComponent("ack-legacy")

        try await AppUpdater.acknowledgeSuccessfulLaunch(
            arguments: [
                "Click-n-speak",
                "--update-validation-token", token,
                "--update-ack-path", acknowledgementURL.path,
            ],
            paths: paths,
            status: .ready
        )

        XCTAssertEqual(try String(contentsOf: acknowledgementURL, encoding: .utf8), token)
    }

    func testPartialStructuredAcknowledgementIsRejected() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let acknowledgementURL = paths.updatesDirectory.appendingPathComponent("ack-partial")

        do {
            try await AppUpdater.acknowledgeSuccessfulLaunch(
                arguments: [
                    "Click-n-speak",
                    "--update-validation-token", UUID().uuidString,
                    "--update-ack-path", acknowledgementURL.path,
                    "--update-candidate-version", "2.0.0",
                ],
                paths: paths,
                status: .ready
            )
            XCTFail("Expected partial acknowledgement schema rejection")
        } catch let error as AppUpdaterError {
            XCTAssertEqual(error, .invalidLaunchAcknowledgement)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgementURL.path))
    }

    func testValidatedStagingStaysInsideInjectedUpdateDirectory() async throws {
        let data = Data("fixture-dmg".utf8)
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: FixtureArchiveDownloader(data: data),
            mounter: FixtureMounter(),
            verifier: AcceptingCandidateVerifier(),
            diskCapacity: { _ in 10_000_000_000 },
            currentVersion: { "1.0.0" }
        )
        _ = try await updater.downloadAndStage(
            update: fixtureUpdate(data: data),
            operationID: UUID(),
            progress: { _ in }
        )
        let contents = try FileManager.default.contentsOfDirectory(atPath: paths.updatesDirectory.path)
        let stagingFolders = contents.filter { $0.hasPrefix("staging-") }
        XCTAssertEqual(stagingFolders.count, 1)
    }

    func testChecksumFailureCleansAbandonedStaging() async throws {
        let data = Data("fixture-dmg".utf8)
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: FixtureArchiveDownloader(data: data),
            mounter: FixtureMounter(),
            verifier: AcceptingCandidateVerifier(),
            diskCapacity: { _ in 10_000_000_000 }
        )
        let update = fixtureUpdate(data: data, checksum: String(repeating: "0", count: 64))
        do {
            _ = try await updater.downloadAndStage(update: update, operationID: UUID(), progress: { _ in })
            XCTFail("Expected checksum mismatch")
        } catch let error as AppUpdaterError {
            XCTAssertEqual(error, .archiveChecksumMismatch)
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: paths.updatesDirectory.path)) ?? []
        XCTAssertTrue(entries.isEmpty)
    }

    func testCancellationCleansAbandonedStaging() async throws {
        let data = Data("fixture-dmg".utf8)
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: FixtureArchiveDownloader(data: data, error: CancellationError()),
            mounter: FixtureMounter(),
            verifier: AcceptingCandidateVerifier(),
            diskCapacity: { _ in 10_000_000_000 }
        )
        do {
            _ = try await updater.downloadAndStage(update: fixtureUpdate(data: data), operationID: UUID(), progress: { _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: paths.updatesDirectory.path)) ?? []
        XCTAssertTrue(entries.isEmpty)
    }

    func testStaleCancellationDoesNotInvalidateAnotherDownload() async throws {
        let data = Data("fixture-dmg".utf8)
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let verifier = SuspendedCandidateVerifier()
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: FixtureArchiveDownloader(data: data),
            mounter: FixtureMounter(),
            verifier: verifier,
            diskCapacity: { _ in 10_000_000_000 },
            currentVersion: { "1.0.0" }
        )
        let currentOperationID = UUID()
        let update = fixtureUpdate(data: data)
        let download = Task {
            try await updater.downloadAndStage(
                update: update,
                operationID: currentOperationID,
                progress: { _ in }
            )
        }
        await verifier.waitUntilStarted()
        await updater.cancelAndCleanUp(operationID: UUID())
        await verifier.release()

        let handle = try await download.value
        XCTAssertEqual(handle.operationID, currentOperationID)
    }

    func testMissingInstallHelperKeepsValidatedStagingForRetry() async throws {
        let data = Data("fixture-dmg".utf8)
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureDataDirectory()
        let target = paths.dataDirectory.appendingPathComponent("Click-n-speak.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: FixtureArchiveDownloader(data: data),
            mounter: FixtureMounter(),
            verifier: AcceptingCandidateVerifier(),
            diskCapacity: { _ in 10_000_000_000 },
            currentVersion: { "1.0.0" },
            targetApplicationURL: target,
            helperExecutableURL: paths.dataDirectory.appendingPathComponent("missing-helper")
        )
        let handle = try await updater.downloadAndStage(
            update: fixtureUpdate(data: data),
            operationID: UUID(),
            progress: { _ in }
        )

        do {
            _ = try await updater.beginInstallation(handle: StagedUpdateHandle(
                operationID: handle.operationID,
                version: "3.0.0"
            ))
            XCTFail("A mismatched version must not install the staged candidate")
        } catch let error as AppUpdaterError {
            XCTAssertEqual(error, .stagedCandidateMissing)
        }

        do {
            _ = try await updater.beginInstallation(handle: handle)
            XCTFail("Expected a missing helper error")
        } catch let error as AppUpdaterError {
            XCTAssertEqual(error, .helperMissing)
        }
        let staging = paths.updatesDirectory.appendingPathComponent("staging-\(handle.operationID.uuidString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".Click-n-speak.update-") })
    }

    func testHelperThatExitsBeforeReadinessDoesNotTerminateParent() async throws {
        let data = Data("fixture-dmg".utf8)
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureDataDirectory()
        let candidate = try makeBundle(version: "2.0.0", build: "20")
        defer { try? FileManager.default.removeItem(at: candidate) }
        let target = paths.dataDirectory.appendingPathComponent("Click-n-speak.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: FixtureArchiveDownloader(data: data),
            mounter: BundleFixtureMounter(bundle: candidate),
            verifier: AcceptingCandidateVerifier(),
            diskCapacity: { _ in 10_000_000_000 },
            currentVersion: { "1.0.0" },
            targetApplicationURL: target,
            helperExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        let handle = try await updater.downloadAndStage(
            update: fixtureUpdate(data: data),
            operationID: UUID(),
            progress: { _ in }
        )

        do {
            _ = try await updater.beginInstallation(handle: handle)
            XCTFail("A helper that exits before readiness must not authorize termination")
        } catch let error as AppUpdaterError {
            XCTAssertEqual(error, .helperNotReady)
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".Click-n-speak.update-") })
    }

    private func temporaryPaths() -> Paths {
        Paths(mode: .dev, environment: [
            "CNS_DATA_DIR": FileManager.default.temporaryDirectory
                .appendingPathComponent("updater-\(UUID().uuidString)").path,
        ])
    }

    private func makeBundle(version: String, build: String) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-bundle-\(UUID().uuidString).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let executableDirectory = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executableURL = executableDirectory.appendingPathComponent("UpdateFixture")
        try Data("fixture-executable".utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.sergej.clicknspeak.fixture",
            "CFBundleExecutable": "UpdateFixture",
            "CFBundleName": "Update Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        return bundleURL
    }

    private func fixtureUpdate(
        data: Data,
        checksum: String? = nil
    ) -> AppUpdate {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AppUpdate(
            version: "2.0.0",
            downloadURL: URL(string: "https://example.invalid/update.dmg")!,
            releaseNotes: "",
            publishedAt: Date(),
            sha256: checksum ?? digest,
            archiveSize: Int64(data.count),
            architecture: .arm64,
            minimumMacOS: "14.0",
            channel: .stable,
            bundleIdentifier: "com.sergej.clicknspeak",
            teamIdentifier: "ABCDE12345"
        )
    }
}

private final class LockedProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.withLock { storage.append(value) }
    }

    var values: [Double] { lock.withLock { storage } }
}
