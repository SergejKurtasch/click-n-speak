import AppKit
import SwiftUI
import CNSCore

@MainActor
public final class StatisticsPanel: NSWindow {
    private let viewModel: StatisticsViewModel

    public init(i18n: I18n, openHistory: @escaping () -> Void, fetchMetrics: @escaping (UUID) async throws -> JSONObject) {
        let viewModel = StatisticsViewModel(i18n: i18n, openHistory: openHistory, fetchMetrics: fetchMetrics)
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = i18n.t("stats.title")
        minSize = NSSize(width: 500, height: 300)
        isReleasedWhenClosed = false
        contentViewController = NSHostingController(rootView: StatisticsView(viewModel: viewModel))
        center()
        
        // Immediately fetch when initialized, or expose a load() method
        viewModel.load()
    }

    public func refresh() { viewModel.load() }
    
    // Test access
    var stateForTesting: StatisticsPresentationState { viewModel.state }
}

private struct StatisticsView: View {
    @ObservedObject var viewModel: StatisticsViewModel

    var body: some View {
        VStack {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView(viewModel.i18n.t("stats.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 12) {
                    Text(viewModel.i18n.t("stats.failed")).foregroundStyle(.red)
                    HStack {
                        Button(viewModel.i18n.t("btn.retry")) { viewModel.load() }
                        Button(viewModel.i18n.t("btn.close")) { NSApp.keyWindow?.close() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(_, let metrics):
                metricsView(metrics)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
    
    @ViewBuilder
    private func metricsView(_ metrics: JSONObject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Replicate the text presentation from MenuBarController
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.formatMetrics(metrics))
                        .font(.system(.body, design: .monospaced))
                        .lineSpacing(4)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(viewModel.i18n.t("stats.btn_history")) {
                    viewModel.openHistory()
                    NSApp.keyWindow?.close()
                }
                Button(viewModel.i18n.t("btn.close")) { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

@MainActor
private final class StatisticsViewModel: ObservableObject {
    let i18n: I18n
    let openHistory: () -> Void
    let fetchMetrics: (UUID) async throws -> JSONObject
    
    @Published var state: StatisticsPresentationState = .idle
    private var currentTask: Task<Void, Never>?
    
    init(i18n: I18n, openHistory: @escaping () -> Void, fetchMetrics: @escaping (UUID) async throws -> JSONObject) {
        self.i18n = i18n
        self.openHistory = openHistory
        self.fetchMetrics = fetchMetrics
    }
    
    func load() {
        let requestID = UUID()
        state = .loading(requestID)
        currentTask?.cancel()
        currentTask = Task {
            do {
                let metrics = try await fetchMetrics(requestID)
                if !Task.isCancelled {
                    if case .loading(let id) = state, id == requestID {
                        state = .ready(requestID, metrics)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    if case .loading(let id) = state, id == requestID {
                        state = .failed(requestID)
                    }
                }
            }
        }
    }
    
    // Copy the formatting logic from MenuBarController.presentStatistics
    func formatMetrics(_ metrics: JSONObject) -> String {
        func percentage(_ value: Double?) -> String {
            value.map { String(format: "%.1f%%", $0 * 100) } ?? i18n.t("stats.not_available")
        }
        func trend(_ value: JSONValue?, positiveGood: Bool) -> String {
            guard let delta = value?.objectValue?["delta"]?.doubleValue else {
                return i18n.t("stats.not_available")
            }
            let arrow = delta > 0 ? "↑" : delta < 0 ? "↓" : "→"
            let qualityKey: String
            if abs(delta) < 0.000_000_001 {
                qualityKey = "stats.trend_neutral"
            } else if (delta > 0) == positiveGood {
                qualityKey = "stats.trend_good"
            } else {
                qualityKey = "stats.trend_bad"
            }
            return String(format: "%@ %+.1fpp (%@)", arrow, delta * 100, i18n.t(qualityKey))
        }

        let editScore = percentage(metrics["edit_score_avg"]?.doubleValue)
        let editTrend = trend(metrics["edit_score_avg"], positiveGood: false)
        
        let hitRate = percentage(metrics["dictionary_hit_rate"]?.doubleValue)
        let hitTrend = trend(metrics["dictionary_hit_rate"], positiveGood: true)
        
        let acceptRate = percentage(metrics["suggestion_acceptance_rate"]?.doubleValue)
        let acceptTrend = trend(metrics["suggestion_acceptance_rate"], positiveGood: true)
        
        let promptUtil = percentage(metrics["prompt_utilization"]?.doubleValue)
        let promptTrend = trend(metrics["prompt_utilization"], positiveGood: true)

        let lastCount = metrics["phrases_in_window"]?.intValue ?? 0
        var lines: [String] = []
        lines.append(i18n.t("stats.performance_header", ["n": "\(lastCount)"]))
        lines.append("  \(i18n.t("stats.edit_label")): \(editScore)   \(editTrend)")
        lines.append("  \(i18n.t("stats.hit_rate_label")): \(hitRate)   \(hitTrend)")
        lines.append("  \(i18n.t("stats.acceptance_rate_label")): \(acceptRate)   \(acceptTrend)")
        lines.append("  \(i18n.t("stats.prompt_util_label")): \(promptUtil)   \(promptTrend)")
        
        if let active = metrics["active_terms"]?.intValue {
            lines.append("")
            lines.append("\(i18n.t("stats.active_terms_label")): \(active)")
        }
        if let inactive = metrics["inactive_terms_to_clean"]?.intValue, inactive > 0 {
            lines.append(i18n.t("stats.inactive_clean", ["n": "\(inactive)"]))
        }

        if let helpers = metrics["top_helpers"]?.arrayValue {
            lines.append("")
            lines.append(i18n.t("stats.top_helpers_header"))
            if helpers.isEmpty {
                lines.append(i18n.t("stats.top_helpers_empty"))
            } else {
                for item in helpers {
                    let source = item.objectValue?["source"]?.stringValue ?? "?"
                    let count = item.objectValue?["count"]?.intValue ?? 0
                    lines.append("  \"\(source)\" (\(count)×)")
                }
            }
        }

        if let weight = metrics["dead_weight"]?.objectValue,
           let count = weight["count"]?.intValue, count > 0 {
            lines.append("")
            lines.append(i18n.t("stats.dead_weight_header", ["n": "\(count)"]))
            if let samples = weight["samples"]?.arrayValue {
                for s in samples {
                    if let str = s.stringValue { lines.append("  \"\(str)\"") }
                }
            }
            if let more = weight["more"]?.intValue, more > 0 {
                lines.append(i18n.t("stats.dead_weight_more", ["n": "\(more)"]))
            }
        }

        if let failures = metrics["failed_pairs"]?.arrayValue, !failures.isEmpty {
            lines.append("")
            lines.append(i18n.t("stats.failed_pairs_header"))
            for item in failures {
                let source = item.objectValue?["source"]?.stringValue ?? "?"
                let target = item.objectValue?["target"]?.stringValue ?? "?"
                let count = item.objectValue?["count"]?.intValue ?? 0
                lines.append("  \"\(source)\" → \"\(target)\" (\(count)×)")
            }
        }
        
        return lines.joined(separator: "\n")
    }
}
