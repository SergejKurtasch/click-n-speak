import Foundation
import CNSCore

/// Chunking parameters. Defaults match `AudioRecorder.__init__` in
/// `recorder.py` (`silence_duration` comes from config, default 1.0 in the app).
public struct ChunkingConfig: Sendable {
    public var sampleRate: Int
    public var silenceDuration: Double      // normal pause threshold
    public var targetSpeechDuration: Double // start looking for micro-pauses
    public var maxSpeechDuration: Double    // force split
    public var minSpeechDuration: Double    // min active speech to keep a chunk

    public init(
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
    }
}

/// What the recorder should do with its accumulated audio after a block.
public enum ChunkDecision: Equatable, Sendable {
    case `continue`                  // keep accumulating
    case emit(triggerType: String)   // emit accumulated audio as a chunk, then reset
    case discard                     // drop accumulated audio (noise), then reset
}

/// Pure VAD-driven chunking state machine ported 1:1 from `recorder.py`
/// (`_callback` + `_trigger_chunk` + the final-chunk logic in `stop`). It holds
/// no audio samples — it only decides *when* to cut — so it can be exhaustively
/// tested with synthetic input. Per SWIFT_MIGRATION_PLAN.md §4.5 this runs in a
/// consumer task, never in the audio callback.
///
/// Usage per audio block:
///   chunker.beginBlock(samples:)              // advances duration/sample counts
///   chunker.voiceFrame(isSpeech:seconds:)     // one or more times (VAD frames / RMS block)
///   let decision = chunker.endBlock()         // trigger check + reset on trigger
public struct AudioChunker: Sendable {
    public let config: ChunkingConfig

    private var silenceCounter: Double = 0
    private var hasSpeechInChunk = false
    private var currentChunkDuration: Double = 0
    private var totalSamples: Int = 0

    public init(config: ChunkingConfig = ChunkingConfig()) {
        self.config = config
    }

    /// Accumulate one audio block (mirrors appending to `audio_data` and
    /// `current_chunk_duration += frames / sample_rate`).
    public mutating func beginBlock(samples: Int) {
        totalSamples += samples
        currentChunkDuration += Double(samples) / Double(config.sampleRate)
    }

    /// Feed one voice-activity result. For libfvad this is one 30 ms frame; for
    /// the RMS fallback it is the whole block treated as a single frame.
    /// Mirrors the per-frame `silence_counter` / `has_speech_in_chunk` updates.
    public mutating func voiceFrame(isSpeech: Bool, seconds: Double) {
        if isSpeech {
            silenceCounter = 0
            hasSpeechInChunk = true
        } else {
            silenceCounter += seconds
        }
    }

    /// Run the end-of-block trigger check. Returns the decision and resets chunk
    /// state on any trigger (emit or discard), exactly as the Python callback
    /// resets `audio_data` / counters.
    public mutating func endBlock() -> ChunkDecision {
        let effectiveSilence: Double
        let triggerType: String
        if currentChunkDuration >= config.maxSpeechDuration {
            effectiveSilence = 0
            triggerType = "FORCE (Max duration)"
        } else if currentChunkDuration >= config.targetSpeechDuration {
            effectiveSilence = 0.4
            triggerType = "MICRO (Target duration)"
        } else {
            effectiveSilence = config.silenceDuration
            triggerType = "Normal"
        }

        guard silenceCounter >= effectiveSilence else {
            return .continue
        }

        var decision: ChunkDecision = .discard
        if totalSamples > 0 && hasSpeechInChunk {
            let duration = Double(totalSamples) / Double(config.sampleRate)
            let speechDuration = duration - silenceCounter
            if speechDuration > config.minSpeechDuration {
                decision = .emit(triggerType: triggerType)
            }
        }
        reset()
        return decision
    }

    private mutating func reset() {
        silenceCounter = 0
        hasSpeechInChunk = false
        currentChunkDuration = 0
        totalSamples = 0
    }

    /// Final-chunk guard from `recorder.stop`: discard a trailing chunk shorter
    /// than 0.3 s (almost always post-speech silence that makes Whisper
    /// hallucinate). Returns true if the final `sampleCount` should be kept.
    public func shouldKeepFinalChunk(sampleCount: Int) -> Bool {
        let minSamples = Int(Double(config.sampleRate) * 0.3)
        return sampleCount >= minSamples
    }
}
