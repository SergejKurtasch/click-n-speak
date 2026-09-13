import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

old_start = """    func start(callbacks: AudioCallbacks) async throws {
        if let startError { throw startError }
        let shouldSuspend = lock.withLock { () -> Bool in
            startCount += 1
            return suspendStart
        }"""
new_start = """    func start(callbacks: AudioCallbacks) async throws {
        try await start(callbacks: callbacks, settings: RecordingSettings())
    }

    func start(callbacks: AudioCallbacks, settings: RecordingSettings) async throws {
        if let startError { throw startError }
        let shouldSuspend = lock.withLock { () -> Bool in
            startCount += 1
            return suspendStart
        }"""

content = content.replace(old_start, new_start)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
