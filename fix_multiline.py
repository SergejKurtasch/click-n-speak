import sys

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    content = f.read()

content = content.replace("            promptLanguages: Set(pending.keys),", "            languages: Set(pending.keys),")

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write(content)
