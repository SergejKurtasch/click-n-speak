import sys

with open("Packages/CNSUI/Sources/CNSUI/TermsPanel.swift", "r") as f:
    content = f.read()

content = content.replace("private let coordinator: DictionaryCoordinator", "let coordinator: DictionaryCoordinator")

with open("Packages/CNSUI/Sources/CNSUI/TermsPanel.swift", "w") as f:
    f.write(content)
