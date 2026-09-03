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

    func testEmitRuntimeEvent() {
        RuntimeTelemetry.emitRuntimeEvent("test_event", fields: ["test_key": "test_value"])
        // If it doesn't crash, it passes for now
    }

    func testTelemetryRejectsContentBearingFieldNames() {
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["transcript_text"]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["initial_prompt"]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["audio_bytes"]))
        XCTAssertFalse(RuntimeTelemetry.fieldsArePrivacySafe(["clipboard_payload"]))
        XCTAssertTrue(RuntimeTelemetry.fieldsArePrivacySafe([
            "duration_ms", "stt_backend", "stt_model", "outcome", "retry_count"
        ]))
    }
}
