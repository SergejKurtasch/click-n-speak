import sys

with open("Packages/CNSUI/Tests/CNSUITests/StatisticsPresentationTests.swift", "r") as f:
    content = f.read()

content += """
    @MainActor
    @Test func testStatisticsPanelLoadingAndFailure() async {
        let i18n = I18n(dict: [:])
        let panel = StatisticsPanel(i18n: i18n, openHistory: {}) { _ in
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        
        // Wait for task to finish
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        switch panel.stateForTesting {
        case .failed:
            break
        default:
            Issue.record("Expected failed state, got \\(panel.stateForTesting)")
        }
    }
    
    @MainActor
    @Test func testStatisticsPanelLoadingAndSuccess() async {
        let i18n = I18n(dict: [:])
        let panel = StatisticsPanel(i18n: i18n, openHistory: {}) { _ in
            return JSONObject([])
        }
        
        // Wait for task to finish
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        switch panel.stateForTesting {
        case .ready:
            break
        default:
            Issue.record("Expected ready state, got \\(panel.stateForTesting)")
        }
    }
"""

with open("Packages/CNSUI/Tests/CNSUITests/StatisticsPresentationTests.swift", "w") as f:
    f.write(content)
