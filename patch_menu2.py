import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

old_open = """                openHistory: { [weak self] in
                    guard let self = self else { return }
                    NSWorkspace.shared.open(self.paths.metricsHistoryFile)
                },"""
new_open = """                openHistory: { [weak self] in
                    guard let self = self else { return }
                    self.openEnsuringFile(self.paths.metricsHistoryFile, defaultContents: "")
                },"""
content = content.replace(old_open, new_open)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
