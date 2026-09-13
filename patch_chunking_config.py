import sys

with open("Packages/CNSAudio/Sources/CNSAudio/AudioChunker.swift", "r") as f:
    content = f.read()

import_str = "import Foundation\nimport CNSCore\n"
content = content.replace("import Foundation\n", import_str)

old_init = """    public init(
        sampleRate: Int = 16000,
        silenceDuration: Double = 1.0,
        targetSpeechDuration: Double = 4.0,
        maxSpeechDuration: Double = 8.0,
        minSpeechDuration: Double = 1.0
    ) {
        self.sampleRate = sampleRate
        self.silenceDuration = silenceDuration
        self.targetSpeechDuration = targetSpeechDuration
        self.maxSpeechDuration = maxSpeechDuration
        self.minSpeechDuration = minSpeechDuration
    }"""

new_init = """    public init(
        sampleRate: Int = 16000,
        silenceDuration: Double = 1.0,
        targetSpeechDuration: Double = 4.0,
        maxSpeechDuration: Double = 8.0,
        minSpeechDuration: Double = 1.0
    ) {
        self.sampleRate = sampleRate
        self.silenceDuration = silenceDuration
        self.targetSpeechDuration = targetSpeechDuration
        self.maxSpeechDuration = maxSpeechDuration
        self.minSpeechDuration = minSpeechDuration
    }
    
    public init(settings: RecordingSettings, sampleRate: Int = 16000) {
        self.sampleRate = sampleRate
        self.silenceDuration = settings.silenceDurationLimit
        self.targetSpeechDuration = settings.targetChunkDuration
        self.maxSpeechDuration = settings.maxChunkDuration
        self.minSpeechDuration = settings.minChunkDuration
    }"""

content = content.replace(old_init, new_init)

with open("Packages/CNSAudio/Sources/CNSAudio/AudioChunker.swift", "w") as f:
    f.write(content)
