import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

old_block = """            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: statisticsPanel,
                queue: .main
            ) { [weak self] _ in self?.statisticsPanel = nil }"""
new_block = """            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: statisticsPanel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.statisticsPanel = nil
                }
            }"""
content = content.replace(old_block, new_block)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
