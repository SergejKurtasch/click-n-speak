import sys

with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "r") as f:
    content = f.read()

import re

match = re.search(r'    func start\(callbacks: AudioCallbacks\) async throws \{\s+lock\.withLock \{\s+self\.callbacks = callbacks\s+recording = true\s+\}\s+\}', content)
if match:
    old_code = match.group(0)
    new_code = """    func start(callbacks: AudioCallbacks) async throws {
        try await start(callbacks: callbacks, settings: RecordingSettings())
    }

    func start(callbacks: AudioCallbacks, settings: RecordingSettings) async throws {
        lock.withLock {
            self.callbacks = callbacks
            recording = true
        }
    }"""
    content = content.replace(old_code, new_code)
    with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "w") as f:
        f.write(content)
else:
    print("Not found regex!")
