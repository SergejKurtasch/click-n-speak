import Foundation

/// Classifies a frame of 16 kHz mono float32 samples as speech or silence.
/// Two implementations exist behind this protocol: the RMS-energy fallback
/// (`RMSVoiceActivityDetector`, ported from the `recorder.py` RMS branch) and,
/// as a follow-up (task 2.2b), a libfvad-backed detector matching webrtcvad.
public protocol VoiceActivityDetecting: Sendable {
    func isSpeech(_ frame: [Float]) -> Bool
}

/// RMS-energy voice activity detection: `sqrt(mean(x²)) >= threshold`. Mirrors
/// the fallback branch in `recorder.py._callback` (`silence_threshold = 0.01`).
public struct RMSVoiceActivityDetector: VoiceActivityDetecting {
    public let threshold: Float

    public init(threshold: Float = 0.01) {
        self.threshold = threshold
    }

    public func isSpeech(_ frame: [Float]) -> Bool {
        guard !frame.isEmpty else { return false }
        var sumSquares: Float = 0
        for sample in frame { sumSquares += sample * sample }
        let rms = (sumSquares / Float(frame.count)).squareRoot()
        return rms >= threshold
    }
}
