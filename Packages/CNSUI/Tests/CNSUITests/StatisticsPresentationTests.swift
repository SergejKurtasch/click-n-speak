import Testing
import Foundation
import CNSCore
import CNSDictionary
@testable import CNSUI

@Suite
struct StatisticsPresentationTests {
    @MainActor
    @Test("An unfinished statistics request does not retain its panel model")
    func unfinishedRequestReleasesModel() async {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales").path) {
            directory = directory.deletingLastPathComponent()
        }
        let i18n = I18n.load("en", localesDirectory: directory.appendingPathComponent("locales"))
        var model: StatisticsViewModel? = StatisticsViewModel(
            i18n: i18n, openHistory: {},
            fetchMetrics: { _ in
                try await Task.sleep(for: .seconds(60))
                return JSONObject()
            }
        )
        weak var weakModel = model
        model?.load()
        model = nil
        for _ in 0..<20 where weakModel != nil { await Task.yield() }
        #expect(weakModel == nil)
    }

    @MainActor
    @Test("Statistics panel accepts a snapshot from the real metrics producer")
    func realProducerSnapshot() {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales").path) {
            directory = directory.deletingLastPathComponent()
        }
        let i18n = I18n.load("en", localesDirectory: directory.appendingPathComponent("locales"))
        let model = StatisticsViewModel(i18n: i18n, openHistory: {}, fetchMetrics: { _ in JSONObject() })
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var terms = JSONObject()
        terms["en"] = .array([.string("Swift")])
        let config = JSONObject([("user_terms", .object(terms))])

        let metrics = Metrics.computeMetrics(
            datasetUrl: temporary.appendingPathComponent("dataset.jsonl"),
            correctionsUrl: temporary.appendingPathComponent("corrections.json"),
            config: config
        )

        let formatted = model.formatMetrics(metrics)
        #expect(formatted.contains("last 0 phrases"))
        #expect(formatted.contains("Active terms: 1"))
    }

    @MainActor
    @Test("Statistics presentation reads the metrics producer schema")
    func producerSchema() {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales").path) {
            directory = directory.deletingLastPathComponent()
        }
        let i18n = I18n.load("en", localesDirectory: directory.appendingPathComponent("locales"))
        let model = StatisticsViewModel(i18n: i18n, openHistory: {}, fetchMetrics: { _ in JSONObject() })
        let metrics = JSONObject([
            ("current_window_count", .int(23)),
            ("edit_score_avg", .double(0.25)),
            ("edit_score_trend", .object(JSONObject([("delta", .double(-0.1))]))),
            ("hit_rate", .double(0.5)),
            ("hit_rate_trend", .object(JSONObject([("delta", .double(0.1))]))),
            ("acceptance_rate", .double(0.75)),
            ("prompt_utilisation", .double(0.4)),
            ("active_terms_count", .int(5)),
            ("inactive_terms_count", .int(2)),
            ("failed_pairs", .array([.object(JSONObject([
                ("from", .string("teh")),
                ("to", .string("the")),
                ("count", .int(3)),
            ]))])),
        ])

        let formatted = model.formatMetrics(metrics)
        #expect(formatted.contains("last 23 phrases"))
        #expect(formatted.contains("25.0%"))
        #expect(formatted.contains("50.0%"))
        #expect(formatted.contains("75.0%"))
        #expect(formatted.contains("40.0%"))
        #expect(formatted.contains("Active terms: 5"))
        #expect(formatted.contains("\"teh\" → \"the\" (3×)"))
        #expect(formatted.contains("↓ -10.0pp"))
        #expect(formatted.contains("↑ +10.0pp"))
    }

    @Test func stateEquality() {
        let id1 = UUID()
        let id2 = UUID()
        let dict1 = JSONObject([])
        let dict2 = JSONObject([("b", .int(2))])

        #expect(StatisticsPresentationState.idle == StatisticsPresentationState.idle)
        #expect(StatisticsPresentationState.loading(id1) == StatisticsPresentationState.loading(id1))
        #expect(StatisticsPresentationState.loading(id1) != StatisticsPresentationState.loading(id2))

        #expect(StatisticsPresentationState.ready(id1, dict1) == StatisticsPresentationState.ready(id1, dict2))
        #expect(StatisticsPresentationState.ready(id1, dict1) != StatisticsPresentationState.ready(id2, dict1))

        #expect(StatisticsPresentationState.failed(id1) == StatisticsPresentationState.failed(id1))
        #expect(StatisticsPresentationState.failed(id1) != StatisticsPresentationState.failed(id2))

        #expect(StatisticsPresentationState.idle != StatisticsPresentationState.loading(id1))
    }
}
