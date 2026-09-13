import sys

with open("Packages/CNSCore/Sources/CNSCore/SessionProtocols.swift", "r") as f:
    content = f.read()

old_start = """    func start(callbacks: AudioCallbacks) async throws"""
new_start = """    func start(callbacks: AudioCallbacks, settings: RecordingSettings) async throws"""

content = content.replace(old_start, new_start)

with open("Packages/CNSCore/Sources/CNSCore/SessionProtocols.swift", "w") as f:
    f.write(content)
