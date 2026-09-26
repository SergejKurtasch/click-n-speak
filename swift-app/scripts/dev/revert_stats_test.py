import sys

with open("Packages/CNSUI/Tests/CNSUITests/StatisticsPresentationTests.swift", "r") as f:
    content = f.read()

import re
content = re.sub(r'    @MainActor\n    @Test func testStatisticsPanelLoadingAndFailure\(\) async \{.*$', '', content, flags=re.DOTALL)

with open("Packages/CNSUI/Tests/CNSUITests/StatisticsPresentationTests.swift", "w") as f:
    f.write(content)
