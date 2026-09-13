import sys

with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "r") as f:
    content = f.read()

old_start = """    func start(callbacks: AudioCallbacks) async throws {
        lock.withLock {
            recording = true
            startedCount += 1
        }
    }"""
new_start = """    func start(callbacks: AudioCallbacks) async throws {
        try await start(callbacks: callbacks, settings: RecordingSettings())
    }

    func start(callbacks: AudioCallbacks, settings: RecordingSettings) async throws {
        lock.withLock {
            recording = true
            startedCount += 1
        }
    }"""

if old_start in content:
    content = content.replace(old_start, new_start)
else:
    print("Could not find start in RuntimeSessionRecorder")

with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "w") as f:
    f.write(content)
