import sys

with open("Packages/CNSUI/Tests/CNSUITests/StatisticsPresentationTests.swift", "r") as f:
    content = f.read()

content = content.replace('let dict1 = JSONObject(raw: [:])', 'let dict1 = JSONObject([])')
content = content.replace('let dict2 = JSONObject(raw: ["b": .int(2)])', 'let dict2 = JSONObject([("b", .int(2))])')

with open("Packages/CNSUI/Tests/CNSUITests/StatisticsPresentationTests.swift", "w") as f:
    f.write(content)
