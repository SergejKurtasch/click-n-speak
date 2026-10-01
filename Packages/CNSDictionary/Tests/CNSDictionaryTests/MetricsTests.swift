import XCTest
import CNSCore
@testable import CNSDictionary

final class MetricsTests: XCTestCase {
    func testMetricsCollection() {
        let dummyURL = URL(fileURLWithPath: "/tmp/dummy")
        let metrics = Metrics.computeMetrics(
            datasetUrl: dummyURL,
            correctionsUrl: dummyURL,
            config: JSONObject()
        )

        // Assert some basic structures are initialized correctly
        XCTAssertNotNil(metrics["ts"])
        XCTAssertNotNil(metrics["window_size"])
        XCTAssertNotNil(metrics["dataset_records_total"])
    }

    func testHistoryPrunesOldRowsAndSkipsMalformedJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-metrics-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("metrics_history.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var old = JSONObject()
        old["ts"] = .string(ISOTimestamp.now(now.addingTimeInterval(-400 * 86_400)))
        old["edit_score_avg"] = .double(0.1)
        try Data((JSONValue.object(old).serializedJSONLine() + "\nmalformed\n").utf8).write(to: url)

        var current = JSONObject()
        current["ts"] = .string(ISOTimestamp.now(now))
        current["edit_score_avg"] = .double(0.2)
        try Metrics.appendHistory(current, to: url, keepDays: 365, now: now)

        let rows = Metrics.loadHistory(at: url)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["edit_score_avg"]?.doubleValue, 0.2)
    }

    func testPromptUtilisationAndDictionaryHealthAreRealValues() {
        var config = JSONObject()
        config["primary_language"] = .string("en")
        var term = JSONObject()
        term["term"] = .string("SwiftUI")
        term["source"] = .string("manual")
        term["added_at"] = .string("2026-01-01T00:00:00+00:00")
        term["last_seen"] = .string("2026-01-01T00:00:00+00:00")
        term["use_count"] = .int(2)
        var terms = JSONObject()
        terms["en"] = .array([.object(term)])
        config["user_terms"] = .object(terms)

        let metrics = Metrics.computeMetrics(
            datasetUrl: URL(fileURLWithPath: "/nonexistent/dataset"),
            correctionsUrl: URL(fileURLWithPath: "/nonexistent/corrections"),
            config: config,
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(metrics["active_terms_count"]?.intValue, 1)
        XCTAssertGreaterThan(metrics["prompt_tokens_used"]?.intValue ?? 0, 0)
        XCTAssertGreaterThan(metrics["prompt_utilisation"]?.doubleValue ?? 0, 0)
    }
}
