import XCTest
@testable import CNSCore
@testable import CNSTranscription
@testable import CNSUI

private actor FileActionHarness {
    private var progressCallbacks: [@Sendable (FileTranscriptionProgress) -> Void] = []
    private var continuations: [Int: CheckedContinuation<FileTranscriptionResult, Never>] = [:]
    private(set) var urls: [URL] = []

    func run(
        url: URL,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        let index = urls.count
        urls.append(url)
        progressCallbacks.append(progress)
        return await withCheckedContinuation { continuations[index] = $0 }
    }

    func waitForCallCount(_ count: Int) async {
        while urls.count < count { await Task.yield() }
    }

    func emit(_ update: FileTranscriptionProgress, call index: Int) {
        progressCallbacks[index](update)
    }

    func finish(_ result: FileTranscriptionResult, call index: Int) {
        continuations.removeValue(forKey: index)?.resume(returning: result)
    }
}

@MainActor
final class FileTranscriptionViewModelTests: XCTestCase {
    func testCancelWaitsForActualCompletionAndRejectsStaleCallbacksFromPreviousJob() async {
        let harness = FileActionHarness()
        var cancelCount = 0
        let viewModel = FileTranscriptionViewModel(
            i18n: i18n(),
            onTranscribe: { url, _, progress in
                await harness.run(url: url, progress: progress)
            },
            onCancel: { cancelCount += 1 }
        )

        XCTAssertTrue(viewModel.start(URL(fileURLWithPath: "/tmp/first.wav")))
        await harness.waitForCallCount(1)
        let firstID = try! XCTUnwrap(viewModel.jobID)
        viewModel.cancel()

        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertTrue(viewModel.isCancelling)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(viewModel.start(URL(fileURLWithPath: "/tmp/blocked.wav")))
        XCTAssertEqual(viewModel.errorMessage, i18n().t("dialog.file_busy"))

        await harness.finish(
            FileTranscriptionResult(text: "partial first", status: .cancelled, segmentCount: 1),
            call: 0
        )
        await waitUntil { viewModel.jobID == nil }
        XCTAssertEqual(viewModel.transcriptionResult, "partial first")
        XCTAssertEqual(viewModel.errorMessage, i18n().t("dialog.file_cancelled"))

        XCTAssertTrue(viewModel.start(URL(fileURLWithPath: "/tmp/second.wav")))
        await harness.waitForCallCount(2)
        let secondID = try! XCTUnwrap(viewModel.jobID)
        viewModel.receiveProgress(
            .init(stage: .uploading, completedUnits: 99, totalUnits: 100),
            jobID: firstID
        )
        viewModel.receiveResult(
            FileTranscriptionResult(text: "stale result", status: .success),
            jobID: firstID
        )

        XCTAssertEqual(viewModel.jobID, secondID)
        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertNotEqual(viewModel.transcriptionResult, "stale result")
        XCTAssertNotEqual(viewModel.progress.completedUnits, 99)

        await harness.finish(
            FileTranscriptionResult(text: "second result", status: .success, segmentCount: 1),
            call: 1
        )
        await waitUntil { viewModel.jobID == nil }
        XCTAssertEqual(viewModel.transcriptionResult, "second result")
    }

    func testRecreatingPanelContentPreservesAnActiveJobAndUnsavedResult() async {
        let harness = FileActionHarness()
        var cancelCount = 0
        let panel = FileDropPanel(
            i18n: i18n(),
            onTranscribe: { url, _, progress in
                await harness.run(url: url, progress: progress)
            },
            onCancel: { cancelCount += 1 }
        )
        let viewModel = panel.viewModelForTesting

        XCTAssertTrue(viewModel.start(URL(fileURLWithPath: "/tmp/reopen.wav")))
        await harness.waitForCallCount(1)
        let jobID = viewModel.jobID
        panel.close()
        panel.presentPanel()

        XCTAssertEqual(panel.viewModelForTesting.jobID, jobID)
        XCTAssertTrue(panel.viewModelForTesting.isProcessing)
        XCTAssertEqual(cancelCount, 0)

        await harness.finish(
            FileTranscriptionResult(text: "unsaved result", status: .success, segmentCount: 1),
            call: 0
        )
        await waitUntil { !viewModel.isProcessing }
        panel.refreshForPresentation()

        XCTAssertEqual(panel.viewModelForTesting.transcriptionResult, "unsaved result")
        XCTAssertEqual(cancelCount, 0)
        panel.close()
    }

    func testCompletedProgressIsNotPublishedBeforeOptionalRefinementFinishes() async {
        let harness = FileActionHarness()
        let viewModel = FileTranscriptionViewModel(
            i18n: i18n(),
            onTranscribe: { url, _, progress in
                await harness.run(url: url, progress: progress)
            }
        )

        viewModel.refine = true
        XCTAssertTrue(viewModel.start(URL(fileURLWithPath: "/tmp/refine.wav")))
        await harness.waitForCallCount(1)
        await harness.emit(.init(stage: .completed, completedUnits: 1, totalUnits: 1), call: 0)
        await waitUntil { viewModel.progress.stage == .preparing }

        XCTAssertEqual(viewModel.progress.stage, .preparing)
        XCTAssertTrue(viewModel.isProcessing)

        await harness.emit(.init(stage: .refining, completedUnits: 0, totalUnits: 1), call: 0)
        await waitUntil { viewModel.progress.stage == .refining }
        await harness.finish(
            FileTranscriptionResult(text: "refined", status: .success, segmentCount: 1),
            call: 0
        )
        await waitUntil { !viewModel.isProcessing }

        XCTAssertEqual(viewModel.progress.stage, .completed)
        XCTAssertEqual(viewModel.transcriptionResult, "refined")
    }

    private func i18n() -> I18n {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let locales = directory.appendingPathComponent("locales")
            if FileManager.default.fileExists(atPath: locales.path) {
                return I18n.load("en", localesDirectory: locales)
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate repository locales")
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate())
    }
}
