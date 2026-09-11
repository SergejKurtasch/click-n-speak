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
    private var moveCount = 0

    init(failOnMove: Int? = nil) {
        self.failOnMove = failOnMove
    }

    func fileExists(at url: URL) -> Bool { system.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try system.createDirectory(at: url) }
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

    func testFailureMovingCurrentAppDoesNotChangeTarget() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let swap = RecoverableAppSwap(files: FaultingFileOperator(failOnMove: 1))
        XCTAssertThrowsError(try swap.install(staged: fixture.staged, target: fixture.target, backup: fixture.backup))
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "old")
    }

    func testFailureInstallingCandidateRollsBackCurrentApp() throws {
        let fixture = try makeSwapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let swap = RecoverableAppSwap(files: FaultingFileOperator(failOnMove: 2))
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
        let swap = RecoverableAppSwap(files: FaultingFileOperator(failOnMove: 2))

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

private struct AcceptingCandidateVerifier: UpdateCandidateVerifying {
    func verify(candidateURL: URL, policy: CandidateVerificationPolicy) async throws {}
}

final class AppUpdaterStagingTests: XCTestCase {
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
        let candidate = try await updater.downloadAndStage(
            update: fixtureUpdate(data: data),
            progress: { _ in }
        )
        XCTAssertTrue(candidate.path.hasPrefix(paths.updatesDirectory.path + "/"))
        XCTAssertFalse(candidate.path.hasPrefix("/Applications/"))
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
            _ = try await updater.downloadAndStage(update: update, progress: { _ in })
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
            _ = try await updater.downloadAndStage(update: fixtureUpdate(data: data), progress: { _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: paths.updatesDirectory.path)) ?? []
        XCTAssertTrue(entries.isEmpty)
    }

    private func temporaryPaths() -> Paths {
        Paths(mode: .dev, environment: [
            "CNS_DATA_DIR": FileManager.default.temporaryDirectory
                .appendingPathComponent("updater-\(UUID().uuidString)").path,
        ])
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
