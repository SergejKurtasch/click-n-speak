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

@MainActor
@Suite("Runtime telemetry integration", .serialized)
struct RuntimeTelemetryTests {
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
