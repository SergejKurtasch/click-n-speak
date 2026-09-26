import CNSCore
import CNSTranscription

import Foundation
import Testing
@testable import CNSSession

/// Swift Testing propagates the current test through child tasks. A neighboring
/// suite must never contribute evidence to this test's process-global sink.
private final class TestScopedFileSink: RuntimeTelemetrySink, Sendable {
    private let owner: Test.ID
    private let file: FileRuntimeTelemetrySink

    init(logger: FileLogger, owner: Test.ID) {
        self.owner = owner
        self.file = FileRuntimeTelemetrySink(logger: logger)
    }

    func emit(event: String, fields: [String: Any]) {
        guard Test.current?.id == owner else { return }
        file.emit(event: event, fields: fields)
    }

    func drain() async { await file.drain() }
}

private final class TestScopedMemorySink: RuntimeTelemetrySink, Sendable {
    private let owner: Test.ID
    private let memory = InMemoryRuntimeTelemetrySink()
    private let onEmit: @Sendable (String) -> Void

    init(owner: Test.ID, onEmit: @escaping @Sendable (String) -> Void = { _ in }) {
        self.owner = owner
        self.onEmit = onEmit
    }

    func emit(event: String, fields: [String: Any]) {
        guard Test.current?.id == owner else { return }
        onEmit(event)
        memory.emit(event: event, fields: fields)
    }

    func drain() async { await memory.drain() }

    var events: [[String: Any]] {
        memory.jsonLines.compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }
}

private final class PreviewEventOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }

    func clear() {
        lock.withLock { storage.removeAll(keepingCapacity: true) }
    }

    var events: [String] {
        lock.withLock { storage }
    }
}

@MainActor
@Suite("Runtime telemetry integration", .serialized)
struct RuntimeTelemetryTests {
    @Test("Whisper and editor warmup have separate timing and one operation identity")
    func warmupTelemetrySeparatesComponents() async throws {
        let sink = TestScopedMemorySink(owner: try #require(Test.current?.id))
        RuntimeTelemetry.configure(sink: sink)
        defer { RuntimeTelemetry.configure(sink: InMemoryRuntimeTelemetrySink()) }
        let barrier = RefinementBarrier()
        let editor = FakeAiEditor()
        editor.prewarmBarrier = barrier
        var raw = JSONObject()
        raw["schema_version"] = .int(10)
        raw["primary_language"] = .string("en")
        raw["ai_editor_enabled"] = .bool(true)
        let transcriber = FakeTranscriber()
        let controller = SessionController(config: Config(raw: raw), transcriber: transcriber,
            aiEditor: editor, recorder: FakeRecorder(), panel: FakePanel(),
            delivery: FakeDelivery(), frontmost: FakeFrontmost())
        let task = Task { await controller.warmupIfIdle(trigger: .wake) }
        await barrier.waitUntilEntered()
        try await Task.sleep(for: .milliseconds(40))
        await barrier.resume()
        #expect(await task.value)
        let stt = try #require(sink.events.first { $0["event"] as? String == "transcriber_prewarm" })
        let ai = try #require(sink.events.first { $0["event"] as? String == "editor_prewarm" })
        #expect(ai["operation_id"] as? String == stt["operation_id"] as? String)
        #expect(ai["backend"] as? String == "local")
        #expect(ai["model"] as? String == "qwen-test")
        #expect(ai["trigger"] as? String == "wake")
        #expect(ai["outcome"] as? String == "warmed")
        #expect(ai["reason"] as? String == "completed")
        #expect(try #require(ai["duration_ms"] as? Double) > 35)
        #expect(try #require(stt["duration_ms"] as? Double) < #require(ai["duration_ms"] as? Double))
        #expect(await transcriber.reloadCount == 0)
    }

    @Test("Full draft preview telemetry is emitted before the editor returns")
    func draftPreviewPrecedesEditorCompletion() async throws {
        let sink = TestScopedMemorySink(owner: try #require(Test.current?.id))
        RuntimeTelemetry.configure(sink: sink)
        defer { RuntimeTelemetry.configure(sink: InMemoryRuntimeTelemetrySink()) }
        let barrier = RefinementBarrier()
        let editor = FakeAiEditor(refinementBarrier: barrier)
        var raw = JSONObject()
        raw["schema_version"] = .int(10)
        raw["primary_language"] = .string("en")
        raw["additional_languages"] = .array([])
        raw["ai_editor_enabled"] = .bool(true)
        let panel = FakePanel()
        let recorder = FakeRecorder()
        let controller = SessionController(
            config: Config(raw: raw),
            transcriber: FakeTranscriber(texts: ["draft"]),
            aiEditor: editor,
            recorder: recorder,
            panel: panel,
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )

        controller.toggle(now: Date())
        await settle()
        recorder.finalChunk = [Float](repeating: 0.2, count: 16_000)
        controller.toggle(now: Date().addingTimeInterval(1))
        await barrier.waitUntilEntered()

        let events = sink.events
        let names = events.compactMap { $0["event"] as? String }
        #expect(panel.events.contains(.text("draft")))
        #expect(names.filter { $0 == "first_preview_presented" }.count == 1)
        #expect(names.filter { $0 == "draft_preview_presented" }.count == 1)
        #expect(!names.contains("editor_refine"))
        let draft = try #require(events.first { $0["event"] as? String == "draft_preview_presented" })
        #expect(draft["append_mode"] as? Bool == false)
        #expect((draft["stop_to_preview_ms"] as? Double) != nil)

        await barrier.resume()
        await settle()
        await controller.shutdown()
    }

    @Test("A confirmed final recording emits one ordered, finite timing lifecycle")
    func confirmedRecordingHasCompleteTimingLifecycle() async throws {
        let sink = TestScopedMemorySink(owner: try #require(Test.current?.id))
        RuntimeTelemetry.configure(sink: sink)
        defer { RuntimeTelemetry.configure(sink: InMemoryRuntimeTelemetrySink()) }
        let panel = FakePanel()
        let recorder = FakeRecorder()
        let controller = SessionController(
            config: Config(raw: JSONObject([
                ("schema_version", .int(10)),
                ("primary_language", .string("en")),
            ])),
            transcriber: FakeTranscriber(texts: ["draft"]),
            recorder: recorder,
            panel: panel,
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )

        controller.toggle(now: Date())
        await settle()
        recorder.finalChunk = [Float](repeating: 0.2, count: 16_000)
        controller.toggle(now: Date().addingTimeInterval(1))
        while !panel.isShowingInteractive { await Task.yield() }
        while controller.state != .popup(sessionID: 1, targetPID: 4242) {
            await Task.yield()
        }
        panel.userConfirms()
        await settle(120)

        let lifecycleNames = Set([
            "session_start", "session_stop", "first_preview_presented",
            "draft_preview_presented", "session_end",
        ])
        let events = sink.events.filter {
            ($0["session_id"] as? Int) == 1
                && lifecycleNames.contains($0["event"] as? String ?? "")
        }
        let names = events.compactMap { $0["event"] as? String }
        #expect(names == [
            "session_start", "session_stop", "first_preview_presented",
            "draft_preview_presented", "session_end",
        ])
        #expect(events.allSatisfy { ($0["monotonic"] as? Double)?.isFinite == true })

        let stop = try #require(events.first { $0["event"] as? String == "session_stop" })
        let first = try #require(events.first { $0["event"] as? String == "first_preview_presented" })
        let draft = try #require(events.first { $0["event"] as? String == "draft_preview_presented" })
        let confirm = try #require(events.first { $0["event"] as? String == "session_end" })
        #expect(try #require(stop["monotonic"] as? Double) <= #require(first["monotonic"] as? Double))
        #expect(try #require(first["monotonic"] as? Double) <= #require(draft["monotonic"] as? Double))
        #expect(try #require(draft["monotonic"] as? Double) <= #require(confirm["monotonic"] as? Double))
        #expect((draft["stop_to_preview_ms"] as? Double) != nil)
        #expect((confirm["stop_to_enter_ms"] as? Double) != nil)
        #expect(confirm["reason"] as? String == "confirm")

        await controller.shutdown()
    }

    @Test("Append partial and final previews emit one ordered event pair")
    func appendPreviewTelemetryIsOrderedAndExactlyOnce() async throws {
        let order = PreviewEventOrderRecorder()
        let sink = TestScopedMemorySink(
            owner: try #require(Test.current?.id),
            onEmit: { order.append("telemetry:\($0)") }
        )
        RuntimeTelemetry.configure(sink: sink)
        defer { RuntimeTelemetry.configure(sink: InMemoryRuntimeTelemetrySink()) }
        let barrier = RefinementBarrier()
        let editor = FakeAiEditor(refinementBarrier: barrier)
        var raw = JSONObject()
        raw["schema_version"] = .int(10)
        raw["primary_language"] = .string("en")
        raw["additional_languages"] = .array([])
        raw["ai_editor_enabled"] = .bool(false)
        let config = Config(raw: raw)
        let panel = FakePanel()
        panel.onEvent = { event in
            guard case let .pending(text, _) = event else { return }
            order.append("pending:\(text)")
        }
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(texts: ["old popup", "partial append", "final append"])
        let controller = SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: recorder,
            panel: panel,
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )
        let base = Date()

        controller.toggle(now: base)
        await settle()
        recorder.finalChunk = [Float](repeating: 0.2, count: 16_000)
        controller.toggle(now: base.addingTimeInterval(1))
        await settle(40)
        #expect(panel.currentText == "old popup")
        order.clear()

        raw["ai_editor_enabled"] = .bool(true)
        controller.updateConfig(Config(raw: raw))
        controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        let beforeSpeech = sink.events.filter { $0["session_id"] as? Int == 2 }
        #expect(beforeSpeech.allSatisfy {
            let event = $0["event"] as? String
            return event != "first_preview_presented" && event != "draft_preview_presented"
        })

        recorder.emitChunk([Float](repeating: 0.2, count: 16_000))
        await transcriber.waitUntilRequestCount(2)
        await settle()
        var appendEvents = sink.events.filter { $0["session_id"] as? Int == 2 }
        #expect(panel.pendingText == "partial append")
        #expect(appendEvents.filter { $0["event"] as? String == "first_preview_presented" }.count == 1)
        #expect(appendEvents.filter { $0["event"] as? String == "draft_preview_presented" }.isEmpty)

        recorder.finalChunk = [Float](repeating: 0.2, count: 16_000)
        controller.toggle(now: base.addingTimeInterval(3))
        await barrier.waitUntilEntered()
        appendEvents = sink.events.filter { $0["session_id"] as? Int == 2 }
        let previewEvents = appendEvents.filter {
            let event = $0["event"] as? String
            return event == "first_preview_presented" || event == "draft_preview_presented"
        }
        #expect(panel.pendingText == "partial append final append")
        #expect(previewEvents.compactMap { $0["event"] as? String } == [
            "first_preview_presented", "draft_preview_presented",
        ])
        #expect(previewEvents.allSatisfy { $0["append_mode"] as? Bool == true })
        #expect((previewEvents.last?["stop_to_preview_ms"] as? Double) != nil)

        let ordered = order.events
        let partialHandoff = ordered.firstIndex(of: "pending:partial append")
        let firstEvent = ordered.firstIndex(of: "telemetry:first_preview_presented")
        let finalHandoff = ordered.firstIndex(of: "pending:partial append final append")
        let draftEvent = ordered.firstIndex(of: "telemetry:draft_preview_presented")
        if let partialHandoff, let firstEvent, let finalHandoff, let draftEvent {
            #expect(partialHandoff < firstEvent)
            #expect(firstEvent < finalHandoff)
            #expect(finalHandoff < draftEvent)
        } else {
            Issue.record("Missing pending/telemetry ordering evidence: \(ordered)")
        }

        await barrier.resume()
        await settle()
        await controller.shutdown()
    }

    @Test("A synthetic session persists privacy-safe events through the file logger sink")
    func syntheticSessionPersistsToFileLogger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-telemetry-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("click-n-speak.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = FileLogger(fileURL: logURL, alsoConsole: false)
        RuntimeTelemetry.configure(
            sink: TestScopedFileSink(logger: logger, owner: try #require(Test.current?.id)),
            runID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        defer { RuntimeTelemetry.configure(sink: InMemoryRuntimeTelemetrySink()) }
        await Task.detached {
            RuntimeTelemetry.emitRuntimeEvent("session_start", fields: ["session_id": 999])
            RuntimeTelemetry.emitRuntimeEvent("session_end", fields: ["session_id": 999, "reason": "cancel"])
        }.value

        var raw = JSONObject()
        raw["schema_version"] = .int(10)
        raw["primary_language"] = .string("en")
        raw["additional_languages"] = .array([])
        raw["initial_prompt"] = .string("PRIVATE_PROMPT_SENTINEL")
        let panel = FakePanel()
        let recorder = FakeRecorder()
        let transcript = "PRIVATE_TRANSCRIPT_SENTINEL"
        let transcriber = FakeTranscriber(texts: [transcript])
        let controller = SessionController(
            config: Config(raw: raw),
            transcriber: transcriber,
            recorder: recorder,
            panel: panel,
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            log: { message in Task { await logger.info(message) } }
        )

        controller.toggle(now: Date())
        await settle()
        recorder.finalChunk = [Float](repeating: 0.2, count: 16_000)
        controller.toggle(now: Date().addingTimeInterval(1))
        await settle(40)
        let selectedTerm = "PRIVATE_SELECTED_TERM_SENTINEL"
        _ = panel.userAddsTerm(selectedTerm)
        panel.userCancels()
        await settle()
        await RuntimeTelemetry.drain()
        await logger.info("telemetry test barrier")

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let eventPayloads = try contents.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let marker = line.range(of: "runtime_event ") else { return nil }
            let json = String(line[marker.upperBound...])
            return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        }
        let eventNames = Set(eventPayloads.compactMap { $0["event"] as? String })

        #expect(eventNames.isSuperset(of: [
            "session_start", "chunk_processed", "popup_presented", "session_end",
        ]))
        assertLifecycle(eventPayloads, starts: [1], reasons: ["cancel"])
        #expect(eventPayloads.filter { $0["event"] as? String == "chunk_processed" }
            .compactMap { $0["chunk_index"] as? Int } == [0])
        #expect(eventPayloads.allSatisfy { $0["run_id"] as? String == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" })
        #expect(eventPayloads.allSatisfy { payload in
            RuntimeTelemetry.fieldsArePrivacySafe(payload)
        })
        #expect(!contents.contains(transcript))
        #expect(!contents.contains("PRIVATE_PROMPT_SENTINEL"))
        #expect(!contents.contains("clipboard"))
        #expect(!contents.contains("\"key\""))
        #expect(!contents.contains(selectedTerm))
    }

    @Test("A no-speech session emits a terminal no-speech outcome")
    func noSpeechSessionHasTerminalOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("runtime.log")
        let sink = TestScopedFileSink(
            logger: FileLogger(fileURL: logURL, alsoConsole: false),
            owner: try #require(Test.current?.id)
        )
        RuntimeTelemetry.configure(
            sink: sink,
            runID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        defer { RuntimeTelemetry.configure(sink: InMemoryRuntimeTelemetrySink()) }
        var raw = JSONObject()
        raw["schema_version"] = .int(10)
        raw["primary_language"] = .string("en")
        raw["additional_languages"] = .array([])
        let panel = FakePanel()
        let recorder = FakeRecorder()
        let controller = SessionController(
            config: Config(raw: raw),
            transcriber: FakeTranscriber(texts: []),
            recorder: recorder,
            panel: panel,
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )

        controller.toggle(now: Date())
        await settle()
        recorder.finalChunk = [Float](repeating: 0.0, count: 16_000)
        controller.toggle(now: Date().addingTimeInterval(1))
        await settle(40)

        await sink.drain()
        assertLifecycle(try readEvents(logURL), starts: [1], reasons: ["no_speech"])
    }

    @Test("Every append recording ends exactly once", arguments: ["normal", "empty", "failure"], [2, 3])
    func appendedRecordingLifecycle(mode: String, count: Int) async throws {
        try await withFileSession { controller, recorder, panel, logURL in
            let base = Date()
            for segment in 0..<count {
                recorder.startError = mode == "failure" && segment > 0
                    ? RecorderErrorStub.failed : nil
                controller.toggle(now: base.addingTimeInterval(Double(segment * 2)))
                await settle()
                if recorder.startError == nil {
                    recorder.finalChunk = mode == "empty" && segment > 0
                        ? nil : [Float](repeating: 0.2, count: 16_000)
                    controller.toggle(now: base.addingTimeInterval(Double(segment * 2 + 1)))
                    await settle(40)
                } else {
                    await settle(40)
                }
                #expect(controller.state == .popup(sessionID: segment + 1, targetPID: 4242))
            }
            if count == 3 {
                panel.userConfirms("final draft")
            } else {
                panel.userCancels()
            }
            await settle(180)
            _ = await controller.shutdown()
            _ = await controller.shutdown()
            await RuntimeTelemetry.drain()
            let events = try readEvents(logURL)
            assertLifecycle(
                events, starts: count == 3 ? [1, 2, 3] : [1, 2],
                reasons: count == 3 ? ["append", "append", "confirm"] : ["append", "cancel"]
            )
            let chunks = events.filter { $0["event"] as? String == "chunk_processed" }
            #expect(chunks.compactMap { $0["chunk_index"] as? Int }
                == (mode == "normal" ? (count == 3 ? [0, 1, 2] : [0, 1]) : [0]))
        }
    }

    @Test("Shutdown closes the recording identity before invalidation", arguments: [false, true])
    func shutdownLifecycle(fromPopup: Bool) async throws {
        try await withFileSession { controller, recorder, _, logURL in
            controller.toggle(now: Date())
            await settle()
            if fromPopup {
                recorder.finalChunk = [Float](repeating: 0.2, count: 16_000)
                controller.toggle(now: Date().addingTimeInterval(1))
                await settle(40)
            }
            _ = await controller.shutdown()
            _ = await controller.shutdown()
            await RuntimeTelemetry.drain()
            assertLifecycle(try readEvents(logURL), starts: [1], reasons: ["shutdown"])
        }
    }

    private func withFileSession(
        _ operation: (SessionController, FakeRecorder, FakePanel, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("runtime.log")
        RuntimeTelemetry.configure(sink: TestScopedFileSink(
            logger: FileLogger(fileURL: logURL, alsoConsole: false),
            owner: try #require(Test.current?.id)
        ))
        defer { RuntimeTelemetry.configure(sink: InMemoryRuntimeTelemetrySink()) }
        let panel = FakePanel()
        let recorder = FakeRecorder()
        var raw = JSONObject()
        raw["schema_version"] = .int(10)
        raw["primary_language"] = .string("en")
        let controller = SessionController(
            config: Config(raw: raw),
            transcriber: FakeTranscriber(texts: ["first", "second", "third"]),
            recorder: recorder, panel: panel, delivery: FakeDelivery(), frontmost: FakeFrontmost()
        )
        try await operation(controller, recorder, panel, logURL)
    }

    private func readEvents(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: "runtime_event ") else { return nil }
            return try JSONSerialization.jsonObject(with: Data(line[marker.upperBound...].utf8)) as? [String: Any]
        }
    }

    private func assertLifecycle(_ events: [[String: Any]], starts: [Int], reasons: [String]) {
        let startEvents = events.filter { $0["event"] as? String == "session_start" }
        let endEvents = events.filter { $0["event"] as? String == "session_end" }
        #expect(startEvents.compactMap { $0["session_id"] as? Int } == starts)
        #expect(endEvents.compactMap { $0["session_id"] as? Int } == starts)
        #expect(endEvents.compactMap { $0["reason"] as? String } == reasons)
    }

    private func settle(_ rounds: Int = 16) async {
        for _ in 0..<rounds {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
