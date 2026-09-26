import XCTest
@testable import CNSCore

final class RuntimeTelemetryTests: XCTestCase {
    func testProcessMetrics() {
        let metrics = RuntimeTelemetry.collectProcessMetrics()
        let parentRSS = metrics["parent_rss_mb"] ?? nil
        let memoryPercent = metrics["system_memory_percent"] ?? nil

        XCTAssertNotNil(parentRSS)
        XCTAssertNotNil(memoryPercent)
        XCTAssertTrue(metrics.keys.contains("child_rss_mb"))
    }

    func testEmitRuntimeEventIncludesRunIdentityAndCanBeDrained() async throws {
        let sink = InMemoryRuntimeTelemetrySink()
        RuntimeTelemetry.configure(
            sink: sink,
            runID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        RuntimeTelemetry.emitRuntimeEvent("test_event", fields: ["test_field": "test_value"])
        await RuntimeTelemetry.drain()

        let line = try XCTUnwrap(sink.jsonLines.first)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["event"] as? String, "test_event")
        XCTAssertEqual(payload["run_id"] as? String, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertNotNil(payload["monotonic"] as? Double)
        XCTAssertNotNil(payload["wall_clock"] as? Double)
    }

    func testTelemetryRejectsContentBearingFieldNames() {
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["transcript_text"]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["initial_prompt"]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["audio_bytes"]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["clipboard_payload"]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["api_key"]))
        XCTAssertTrue(RuntimeTelemetry.fieldsArePrivacySafe([
            "duration_ms", "stt_backend", "stt_model", "outcome", "retry_count"
        ]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe([
            "payload": ["prompt": "private"]
        ]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe([
            "payload": [["key": "private"]]
        ]))
    }
}
