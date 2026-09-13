import sys

with open("Packages/CNSAudio/Sources/CNSAudio/AudioRecorder.swift", "r") as f:
    content = f.read()

old_start = """    public func start(callbacks: Callbacks) async throws {
        let generation: Int? = stateLock.withLock { state in
            if state.recording || state.stopping { return nil }
            state.generation += 1
            state.recording = true
            state.stopping = false
            state.acceptingSamples = false
            state.tapInstalled = false
            state.graphSetupInProgress = false
            state.teardownStarted = false
            state.interruptionReported = false
            state.callbacks = callbacks
            state.chunker = AudioChunker(config: config)"""

new_start = """    public func start(callbacks: Callbacks) async throws {
        try await start(callbacks: callbacks, settings: RecordingSettings(
            silenceDurationLimit: config.silenceDuration,
            targetChunkDuration: config.targetSpeechDuration,
            minChunkDuration: config.minSpeechDuration,
            maxChunkDuration: config.maxSpeechDuration
        ))
    }

    public func start(callbacks: Callbacks, settings: RecordingSettings) async throws {
        let chunkingConfig = ChunkingConfig(settings: settings, sampleRate: config.sampleRate)
        let generation: Int? = stateLock.withLock { state in
            if state.recording || state.stopping { return nil }
            state.generation += 1
            state.recording = true
            state.stopping = false
            state.acceptingSamples = false
            state.tapInstalled = false
            state.graphSetupInProgress = false
            state.teardownStarted = false
            state.interruptionReported = false
            state.callbacks = callbacks
            state.chunker = AudioChunker(config: chunkingConfig)"""

content = content.replace(old_start, new_start)

with open("Packages/CNSAudio/Sources/CNSAudio/AudioRecorder.swift", "w") as f:
    f.write(content)
