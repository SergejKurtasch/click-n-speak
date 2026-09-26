import Foundation

/// Pre-decode audio guards from `transcriber.py`. These decide whether a chunk
/// is worth sending to Whisper at all — decoding silence costs 14-22 s and
/// always hallucinates, so cheap RMS/length checks skip it. Engine-independent.
public enum AudioGuards {
    /// 0.5 s at 16 kHz. Final chunks at or below this are post-speech silence
    /// (`MIN_FINAL_CHUNK_SAMPLES`).
    public static let minFinalChunkSamples = 8000
    /// 3 s at 16 kHz (`_SHORT_CHUNK_SAMPLES`).
    public static let shortChunkSamples = 48000
    /// Calibrated against the MacBook Air mic noise floor (`_SILENCE_RMS_THRESHOLD`).
    public static let silenceRMSThreshold: Float = 0.005

    /// Why a chunk was skipped before decoding, or nil to proceed.
    public enum SkipReason: Equatable, Sendable {
        case tinyFinalChunk   // final chunk ≤ 0.5 s
        case silentShortChunk // non-final < 3 s and near-silent
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// `_is_audio_silent`: RMS below the silence threshold.
    public static func isSilent(_ samples: [Float]) -> Bool {
        rms(samples) < silenceRMSThreshold
    }

    /// Decide whether to skip decoding, mirroring the two guards at the top of
    /// `TranscriberProcessWrapper.transcribe` / `WhisperTranscriber.transcribe`.
    public static func skipReason(sampleCount: Int, samples: [Float], isFinal: Bool) -> SkipReason? {
        if isFinal && sampleCount <= minFinalChunkSamples {
            return .tinyFinalChunk
        }
        if !isFinal && sampleCount < shortChunkSamples && isSilent(samples) {
            return .silentShortChunk
        }
        return nil
    }
}
