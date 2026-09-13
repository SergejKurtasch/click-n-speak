import sys

with open("Packages/CNSSession/Sources/CNSSession/SessionController.swift", "r") as f:
    content = f.read()

old_start = """        chunkContinuation = continuation
        workerTask = Task { [weak self] in
            await self?.runWorker(stream, sessionId: id, audioBacklog: audioBacklog)
        }

        recorderStartTask?.cancel()
        recorderStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.recorderStartTask = nil }
            do {
                try await self.recorder.start(callbacks: self.makeRecorderCallbacks(
                    sessionId: id,
                    audioBacklog: audioBacklog
                ))
                await self.recorderDidStart(sessionId: id)
            } catch is CancellationError {"""

new_start = """        chunkContinuation = continuation
        workerTask = Task { [weak self] in
            await self?.runWorker(stream, sessionId: id, audioBacklog: audioBacklog)
        }

        let recordingSettings = (try? (activeSessionConfig ?? config).recordingSettings) ?? RecordingSettings()

        recorderStartTask?.cancel()
        recorderStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.recorderStartTask = nil }
            do {
                try await self.recorder.start(callbacks: self.makeRecorderCallbacks(
                    sessionId: id,
                    audioBacklog: audioBacklog
                ), settings: recordingSettings)
                await self.recorderDidStart(sessionId: id)
            } catch is CancellationError {"""

content = content.replace(old_start, new_start)

with open("Packages/CNSSession/Sources/CNSSession/SessionController.swift", "w") as f:
    f.write(content)
