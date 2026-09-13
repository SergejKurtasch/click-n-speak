import sys

with open("Packages/CNSUI/Sources/CNSUI/StatisticsPanel.swift", "r") as f:
    content = f.read()

content = content.replace("metrics.raw[", "metrics[")

with open("Packages/CNSUI/Sources/CNSUI/StatisticsPanel.swift", "w") as f:
    f.write(content)
