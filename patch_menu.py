import sys
import re

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

content = content.replace("private var statisticsTask: Task<Void, Never>?", "private var statisticsPanel: StatisticsPanel?")

old_on = """    @objc private func onStatistics() {
        if let dictionaryCoordinator {
            statisticsTask?.cancel()
            statisticsTask = Task { [weak self, weak dictionaryCoordinator] in
                guard let self, let dictionaryCoordinator else { return }
                do {
                    let metrics = try await dictionaryCoordinator.computeMetricsForPresentation()
                    try Task.checkCancellation()
                    self.presentStatistics(metrics)
                } catch is CancellationError {
                    return
                } catch {
                    self.log("Metrics computation failed: \\(error.localizedDescription)")
                    self.presentStatistics(JSONObject())
                }
                self.statisticsTask = nil
            }
            return
        } else {
            presentStatistics(Metrics.computeMetrics(
                datasetUrl: paths.datasetFile,
                correctionsUrl: paths.correctionsFile,
                config: config.raw
            ))
        }
    }"""
new_on = """    @objc private func onStatistics() {
        if statisticsPanel == nil {
            statisticsPanel = StatisticsPanel(
                i18n: i18n,
                openHistory: { [weak self] in
                    guard let self = self else { return }
                    self.openEnsuringFile(self.paths.metricsHistoryFile, defaultContents: "")
                },
                fetchMetrics: { [weak self] _ in
                    if let coordinator = self?.dictionaryCoordinator {
                        return try await coordinator.computeMetricsForPresentation()
                    }
                    guard let self = self else { throw DictionaryCoordinatorError.noSnapshot }
                    return Metrics.computeMetrics(
                        datasetUrl: self.paths.datasetFile,
                        correctionsUrl: self.paths.correctionsFile,
                        config: self.config.raw
                    )
                }
            )
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: statisticsPanel,
                queue: .main
            ) { [weak self] _ in self?.statisticsPanel = nil }
        }
        statisticsPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statisticsPanel?.refresh()
    }"""
content = content.replace(old_on, new_on)

match = re.search(r'    private func presentStatistics\(_ metrics: JSONObject\) \{.*?(?=    @objc private func onTranscribeFile)', content, re.DOTALL)
if match:
    content = content.replace(match.group(0), "")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
