// Regression probes for the 2026-09-07 audit. Uses the existing SessionDoubles.swift fixtures.
import CNSCore
import CNSDictionary
import CNSTranscription
import Foundation
import Testing
@testable import CNSSession

private actor AuditFileTranscriber: Transcribing {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult { .empty }
    func transcribeFile(_ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return FileTranscriptionResult(text: "file text", status: .success)
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor
@Suite("Review audit session probes", .serialized)
struct ReviewAuditSessionProbes {
    private func config() -> Config {
        var config = Config.migrated(JSONObject())
        config.raw["ai_editor_enabled"] = .bool(false)
        return config
    }

    @Test("File transcription must block the recording hotkey")
    func fileJobBlocksHotkey() async throws {
        let transcriber = AuditFileTranscriber()
        let recorder = FakeRecorder()
        let session = SessionController(config: config(), transcriber: transcriber,
            recorder: recorder, panel: FakePanel(), delivery: FakeDelivery(), frontmost: FakeFrontmost())
        let job = Task { await session.transcribeFile(url: URL(fileURLWithPath: "audit.wav")) }
        while !(await transcriber.started) { await Task.yield() }
        session.toggle()
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.startCount == 0)
        await transcriber.finish()
        _ = await job.value
        await session.shutdown()
    }

    @Test("Injection must block a new recording")
    func injectingBlocksHotkey() async throws {
        let recorder = FakeRecorder()
        recorder.finalChunk = [1]
        let panel = FakePanel()
        let session = SessionController(config: config(), transcriber: FakeTranscriber(texts: ["first"]),
            recorder: recorder, panel: panel, delivery: FakeDelivery(), frontmost: FakeFrontmost())
        let base = Date()
        session.toggle(now: base)
        try await Task.sleep(for: .milliseconds(30))
        session.toggle(now: base.addingTimeInterval(1))
        try await Task.sleep(for: .milliseconds(40))
        panel.userConfirms()
        session.toggle(now: base.addingTimeInterval(2))
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.startCount == 1)
        await session.shutdown()
        try await Task.sleep(for: .milliseconds(250))
    }

    @Test("Appending silence must preserve the editable first phrase")
    func silentAppendPreservesPopup() async throws {
        let recorder = FakeRecorder()
        recorder.finalChunk = [1]
        let panel = FakePanel()
        let session = SessionController(config: config(), transcriber: FakeTranscriber(texts: ["first", ""]),
            recorder: recorder, panel: panel, delivery: FakeDelivery(), frontmost: FakeFrontmost())
        let base = Date()
        for index in 0..<4 {
            session.toggle(now: base.addingTimeInterval(Double(index)))
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(panel.isShowingInteractive)
        #expect(panel.shownText == "first")
        await session.shutdown()
    }

    @Test("Append confirmation must keep raw text from both recordings")
    func appendPreservesDatasetSource() async throws {
        let recorder = FakeRecorder()
        recorder.finalChunk = [1]
        let panel = FakePanel()
        let dictionary = FakeDictionaryCoordinator(config: config())
        let session = SessionController(config: config(), transcriber: FakeTranscriber(texts: ["first", "second"]),
            recorder: recorder, panel: panel, delivery: FakeDelivery(), frontmost: FakeFrontmost(),
            dictionaryCoordinator: dictionary)
        let base = Date()
        for index in 0..<4 {
            session.toggle(now: base.addingTimeInterval(Double(index)))
            try await Task.sleep(for: .milliseconds(40))
        }
        panel.userConfirms()
        try await Task.sleep(for: .milliseconds(250))
        #expect(dictionary.confirmations.first?.datasetRecord.rawWhisper == "first second")
        await session.shutdown()
    }

    @Test("A failed middle chunk must produce an incomplete-transcription warning")
    func partialFailureIsVisible() async throws {
        let recorder = FakeRecorder()
        recorder.scriptedChunks = [[1], [1]]
        recorder.finalChunk = [1]
        let panel = FakePanel()
        let transcriber = FakeTranscriber(texts: [], results: [
            .init(text: "first"), .failed(.init(kind: .decode, message: "Decode failed")), .init(text: "third")
        ])
        let session = SessionController(config: config(), transcriber: transcriber,
            recorder: recorder, panel: panel, delivery: FakeDelivery(), frontmost: FakeFrontmost())
        let base = Date()
        session.toggle(now: base)
        try await Task.sleep(for: .milliseconds(30))
        session.toggle(now: base.addingTimeInterval(1))
        try await Task.sleep(for: .milliseconds(80))
        #expect(panel.shownText == "first third")
        #expect(panel.statuses.contains("Decode failed"))
        await session.shutdown()
    }

    @Test("Shutdown must suppress a late editor completion")
    func shutdownCannotReopenPopup() async throws {
        let recorder = FakeRecorder()
        recorder.finalChunk = [1]
        let panel = FakePanel()
        let editor = FakeAiEditor()
        editor.refineDelay = 0.5
        var enabled = config()
        enabled.raw["ai_editor_enabled"] = .bool(true)
        let session = SessionController(config: enabled, transcriber: FakeTranscriber(texts: ["first"]),
            aiEditor: editor, recorder: recorder, panel: panel,
            delivery: FakeDelivery(), frontmost: FakeFrontmost())
        let base = Date()
        session.toggle(now: base)
        try await Task.sleep(for: .milliseconds(30))
        session.toggle(now: base.addingTimeInterval(1))
        while !editor.didCallRefine { await Task.yield() }
        await session.shutdown()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!panel.isShowingInteractive)
        #expect(session.state == .idle)
    }
}
