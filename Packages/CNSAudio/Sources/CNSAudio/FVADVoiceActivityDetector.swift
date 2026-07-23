import Cfvad
import Foundation
import os

/// WebRTC voice activity detection via libfvad — the same algorithm the Python
/// app uses through `webrtcvad`, so the chunking thresholds calibrated against
/// it (1.0 / 0.4 / 0 s silence, target 3 s, max 8 s) carry over unchanged.
///
/// Mode 2 ("moderate") matches `webrtcvad.Vad(2)` in `recorder.py`. libfvad
/// requires 10/20/30 ms frames of 16-bit PCM at 8/16/32/48 kHz; the recorder
/// feeds 30 ms @ 16 kHz (480 samples). Frames of an unsupported length fall back
/// to the RMS detector so no audio is silently dropped.
public final class FVADVoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {
    // @unchecked Sendable: the Fvad instance is not thread-safe, so every use is
    // serialized through `lock`. The recorder calls this from a single consumer
    // task, but the lock keeps the type safe if that ever changes.
    private let handle: OpaquePointer?
    // Plain NSLock rather than OSAllocatedUnfairLock: the latter's withLock
    // closure is @Sendable, which cannot capture the non-Sendable C handle.
    private let lock = NSLock()
    private let fallback: RMSVoiceActivityDetector
    private let sampleRate: Int

    /// Valid libfvad frame lengths at 16 kHz: 10, 20, 30 ms.
    private static let validFrameCounts: Set<Int> = [160, 320, 480]

    public init(sampleRate: Int = 16000, mode: Int32 = 2, fallbackThreshold: Float = 0.01) {
        self.sampleRate = sampleRate
        self.fallback = RMSVoiceActivityDetector(threshold: fallbackThreshold)
        let created = fvad_new()
        if let created {
            fvad_set_mode(created, mode)
            fvad_set_sample_rate(created, Int32(sampleRate))
        }
        self.handle = created
    }

    public func isSpeech(_ frame: [Float]) -> Bool {
        guard let handle, Self.validFrameCounts.contains(frame.count) else {
            return fallback.isSpeech(frame)
        }
        // libfvad wants 16-bit PCM; the recorder works in float32 [-1, 1].
        var pcm = [Int16](repeating: 0, count: frame.count)
        for i in 0..<frame.count {
            let clamped = max(-1.0, min(1.0, frame[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        lock.lock()
        defer { lock.unlock() }
        let result = pcm.withUnsafeBufferPointer { buf in
            fvad_process(handle, buf.baseAddress, buf.count)
        }
        // -1 means an invalid frame length; treat it as silence rather than
        // guessing, the length guard above should already prevent it.
        return result == 1
    }

    deinit {
        if let handle { fvad_free(handle) }
    }
}
