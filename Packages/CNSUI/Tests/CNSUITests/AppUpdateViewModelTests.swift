import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import CNSCore
@testable import CNSUI

private actor SuspendedUpdateCheck {
    private var callCount = 0
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func run(version: String) async -> AppUpdate? {
        callCount += 1
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation in release = continuation }
        return nil
    }

    func waitUntilCalled() async {
        if callCount > 0 { return }
        await withCheckedContinuation { continuation in observer = continuation }
    }

    func count() -> Int { callCount }

    func finish() {
        release?.resume()
        release = nil
    }
}

private actor UpdateArchiveFixture: UpdateArchiveDownloading {
    let data: Data
    private var downloads = 0

    init(data: Data) { self.data = data }

    func download(
        from source: URL,
        to destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        downloads += 1
        try data.write(to: destination)
        progress(1)
    }

    func count() -> Int { downloads }
}

private struct UpdateMountFixture: DiskImageMounting {
    func mount(image: URL, at mountPoint: URL) throws {
        let app = mountPoint.appendingPathComponent("Click-n-speak.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("candidate".utf8).write(to: app.appendingPathComponent("marker"))
    }

    func unmount(_ mountPoint: URL) {}
}

private struct UpdateVerifierFixture: UpdateCandidateVerifying {
    func verify(candidateURL: URL, policy: CandidateVerificationPolicy) async throws {}
}

private actor PausedUpdateVerifier: UpdateCandidateVerifying {
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func verify(candidateURL: URL, policy: CandidateVerificationPolicy) async throws {
        entered?.resume()
        entered = nil
        await withCheckedContinuation { continuation in release = continuation }
    }

    func waitUntilEntered() async {
        if release != nil { return }
        await withCheckedContinuation { continuation in entered = continuation }
    }

    func finish() {
        release?.resume()
        release = nil
    }
}

@MainActor
final class AppUpdateViewModelTests: XCTestCase {
    private func makeI18n() -> I18n {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales/en.json").path) {
                break
            }
            directory.deleteLastPathComponent()
        }
        return I18n.load("en", localesDirectory: directory.appendingPathComponent("locales"))
    }

    func testRepeatedCheckUsesOneRequestUntilItFinishes() async {
        let gate = SuspendedUpdateCheck()
        let updater = AppUpdater(paths: Paths(mode: .dev, environment: [
            "CNS_DATA_DIR": FileManager.default.temporaryDirectory
                .appendingPathComponent("update-check-\(UUID().uuidString)").path,
        ]))
        let viewModel = AppUpdateViewModel(
            updater: updater,
            panel: ModelDownloadPanel(i18n: makeI18n()),
            i18n: makeI18n(),
            checker: { version in await gate.run(version: version) }
        )
        viewModel.checkForUpdates(currentVersion: "1.0.0")
        let firstOperation = viewModel.checkOperationID
        await gate.waitUntilCalled()
        viewModel.checkForUpdates(currentVersion: "1.0.0")
        XCTAssertEqual(viewModel.checkOperationID, firstOperation)
        let count = await gate.count()
        XCTAssertEqual(count, 1)
        await gate.finish()
    }

    func testRepeatedStartAndCancelKeepOneOperationUntilDownloadExits() {
        let i18n = makeI18n()
        let panel = ModelDownloadPanel(i18n: i18n)
        let paths = Paths(mode: .dev, environment: [
            "CNS_DATA_DIR": FileManager.default.temporaryDirectory
                .appendingPathComponent("update-ui-\(UUID().uuidString)").path,
        ])
        let updater = AppUpdater(paths: paths, diskCapacity: { _ in 0 })
        let viewModel = AppUpdateViewModel(updater: updater, panel: panel, i18n: i18n)
        let update = AppUpdate(
            version: "2.0.0",
            downloadURL: URL(string: "https://example.invalid/update.dmg")!,
            releaseNotes: "",
            publishedAt: Date(),
            sha256: String(repeating: "0", count: 64),
            archiveSize: 1,
            architecture: .arm64,
            minimumMacOS: "14.0",
            channel: .stable,
            bundleIdentifier: "com.sergej.clicknspeak",
            teamIdentifier: "ABCDE12345"
        )

        viewModel.startUpdate(update: update)
        let firstOperation = viewModel.activeOperationID
        XCTAssertNotNil(firstOperation)
        viewModel.startUpdate(update: update)
        XCTAssertEqual(viewModel.activeOperationID, firstOperation)

        viewModel.cancelUpdate(operationID: firstOperation!)
        XCTAssertEqual(viewModel.activeOperationID, firstOperation)
        panel.close()
    }

    func testReadyUpdateCanBeReopenedWithoutAnotherDownload() async throws {
        let data = Data("fixture-dmg".utf8)
        let archive = UpdateArchiveFixture(data: data)
        let paths = Paths(mode: .dev, environment: [
            "CNS_DATA_DIR": FileManager.default.temporaryDirectory
                .appendingPathComponent("update-ready-\(UUID().uuidString)").path,
        ])
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: archive,
            mounter: UpdateMountFixture(),
            verifier: UpdateVerifierFixture(),
            diskCapacity: { _ in 10_000_000_000 },
            currentVersion: { "1.0.0" }
        )
        let i18n = makeI18n()
        let panel = ModelDownloadPanel(i18n: i18n)
        let viewModel = AppUpdateViewModel(updater: updater, panel: panel, i18n: i18n)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let update = AppUpdate(
            version: "2.0.0",
            downloadURL: URL(string: "https://example.invalid/update.dmg")!,
            releaseNotes: "",
            publishedAt: Date(),
            sha256: digest,
            archiveSize: Int64(data.count),
            architecture: .arm64,
            minimumMacOS: "14.0",
            channel: .stable,
            bundleIdentifier: "com.sergej.clicknspeak",
            teamIdentifier: "ABCDE12345"
        )
        let ready = expectation(description: "validated candidate is ready")
        var deliveredHandle: StagedUpdateHandle?
        viewModel.onReady = { handle in
            deliveredHandle = handle
            ready.fulfill()
        }

        viewModel.startUpdate(update: update)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(viewModel.readyHandle, deliveredHandle)
        XCTAssertEqual(deliveredHandle?.version, "2.0.0")
        viewModel.startUpdate(update: update)
        let count = await archive.count()
        XCTAssertEqual(count, 1)
        panel.close()
    }

    func testAppValidationDisablesOnlyItsPanelCancellation() async throws {
        let data = Data("fixture-dmg".utf8)
        let paths = Paths(mode: .dev, environment: [
            "CNS_DATA_DIR": FileManager.default.temporaryDirectory
                .appendingPathComponent("update-panel-\(UUID().uuidString)").path,
        ])
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        let verifier = PausedUpdateVerifier()
        let updater = AppUpdater(
            paths: paths,
            archiveDownloader: UpdateArchiveFixture(data: data),
            mounter: UpdateMountFixture(),
            verifier: verifier,
            diskCapacity: { _ in 10_000_000_000 },
            currentVersion: { "1.0.0" }
        )
        let i18n = makeI18n()
        let modelPanel = ModelDownloadPanel(i18n: i18n)
        let modelGeneration = modelPanel.show(modelName: "Whisper", onCancel: {})
        let appPanel = ModelDownloadPanel(i18n: i18n)
        let viewModel = AppUpdateViewModel(updater: updater, panel: appPanel, i18n: i18n)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let update = AppUpdate(
            version: "2.0.0",
            downloadURL: URL(string: "https://example.invalid/update.dmg")!,
            releaseNotes: "",
            publishedAt: Date(),
            sha256: digest,
            archiveSize: Int64(data.count),
            architecture: .arm64,
            minimumMacOS: "14.0",
            channel: .stable,
            bundleIdentifier: "com.sergej.clicknspeak",
            teamIdentifier: "ABCDE12345"
        )
        viewModel.startUpdate(update: update)
        await verifier.waitUntilEntered()
        for _ in 0..<20 where appPanel.statusForTesting != i18n.t("download.app_verifying_candidate") {
            await Task.yield()
        }
        XCTAssertEqual(appPanel.cancelEnabledForTesting, false)
        XCTAssertEqual(appPanel.closeEnabledForTesting, false)
        XCTAssertEqual(modelPanel.cancelEnabledForTesting, true)
        XCTAssertEqual(modelPanel.generationForTesting, modelGeneration)
        await verifier.finish()
        modelPanel.close()
        appPanel.close()
    }
}
