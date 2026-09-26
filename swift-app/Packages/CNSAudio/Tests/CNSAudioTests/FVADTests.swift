import Testing
import Foundation
@testable import CNSAudio

@Suite("FVADVoiceActivityDetector")
struct FVADTests {
    /// 30 ms @ 16 kHz — the frame size the recorder feeds.
    private let frameCount = 480

    private func tone(_ count: Int, freq: Double = 220, amplitude: Float = 0.4) -> [Float] {
        (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * freq * Double(i) / 16000.0))
        }
    }

    private func noise(_ count: Int, amplitude: Float = 0.0005) -> [Float] {
        var seed: UInt64 = 42
        return (0..<count).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(Double(seed >> 33) / Double(UInt32.max)) * 2 - 1
            return unit * amplitude
        }
    }

    @Test("Digital silence is not speech")
    func silence() {
        let vad = FVADVoiceActivityDetector()
        #expect(vad.isSpeech([Float](repeating: 0, count: frameCount)) == false)
    }

    @Test("Near-silent noise floor is not speech")
    func noiseFloor() {
        let vad = FVADVoiceActivityDetector()
        #expect(vad.isSpeech(noise(frameCount)) == false)
    }

    @Test("A loud tone registers as speech")
    func loudTone() {
        let vad = FVADVoiceActivityDetector()
        #expect(vad.isSpeech(tone(frameCount)) == true)
    }

    @Test("Unsupported frame lengths fall back to RMS instead of dropping audio",
          arguments: [100, 333, 1000])
    func fallbackForOddLengths(_ count: Int) {
        let vad = FVADVoiceActivityDetector()
        // Loud frame of an invalid libfvad length must still be seen as speech.
        #expect(vad.isSpeech([Float](repeating: 0.5, count: count)) == true)
        #expect(vad.isSpeech([Float](repeating: 0, count: count)) == false)
    }

    @Test("All valid libfvad frame sizes are accepted", arguments: [160, 320, 480])
    func validFrameSizes(_ count: Int) {
        let vad = FVADVoiceActivityDetector()
        // Should not crash and should classify a loud tone as speech.
        #expect(vad.isSpeech(tone(count)) == true)
    }

    @Test("Detector is reusable across many frames")
    func repeatedUse() {
        let vad = FVADVoiceActivityDetector()
        for _ in 0..<50 {
            _ = vad.isSpeech(tone(frameCount))
            _ = vad.isSpeech([Float](repeating: 0, count: frameCount))
        }
        #expect(vad.isSpeech(tone(frameCount)) == true)
    }
}
