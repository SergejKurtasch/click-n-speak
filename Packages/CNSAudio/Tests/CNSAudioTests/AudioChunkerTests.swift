import Testing
@testable import CNSAudio

@Suite("AudioChunker")
struct AudioChunkerTests {
    private let sr = 16000

    /// Feed one block that is entirely speech or entirely silence (RMS-style:
    /// one voice frame per block), returning the decision.
    private func block(_ chunker: inout AudioChunker, seconds: Double, speech: Bool) -> ChunkDecision {
        chunker.beginBlock(samples: Int(seconds * Double(sr)))
        chunker.voiceFrame(isSpeech: speech, seconds: seconds)
        return chunker.endBlock()
    }

    @Test("Normal branch: 1.0s silence triggers before target duration")
    func normalBranch() {
        var c = AudioChunker()
        // 1.5s speech, total stays below the 4s target.
        #expect(block(&c, seconds: 0.5, speech: true) == .continue)
        #expect(block(&c, seconds: 0.5, speech: true) == .continue)
        #expect(block(&c, seconds: 0.5, speech: true) == .continue)
        // 0.5s + 0.5s silence → silence_counter hits 1.0 at total 2.5s (< 4s).
        #expect(block(&c, seconds: 0.5, speech: false) == .continue)
        #expect(block(&c, seconds: 0.5, speech: false) == .emit(triggerType: "Normal"))
    }

    @Test("Micro branch: 0.4s silence triggers after target (4s) duration")
    func microBranch() {
        var c = AudioChunker()
        // 4.0s of speech reaches target, with no trigger while speech continues.
        for _ in 0..<8 { #expect(block(&c, seconds: 0.5, speech: true) == .continue) }
        // Two 0.2s silence frames → silence_counter 0.4 → Micro trigger.
        #expect(block(&c, seconds: 0.2, speech: false) == .continue)
        #expect(block(&c, seconds: 0.2, speech: false) == .emit(triggerType: "MICRO (Target duration)"))
    }

    @Test("Force branch: any block past max (8s) triggers with zero silence")
    func forceBranch() {
        var c = AudioChunker()
        // 15 blocks of 0.5s = 7.5s speech, still under 8s.
        for _ in 0..<15 { #expect(block(&c, seconds: 0.5, speech: true) == .continue) }
        // 16th block reaches 8.0s → force split even though it's speech (silence 0 ≥ 0).
        #expect(block(&c, seconds: 0.5, speech: true) == .emit(triggerType: "FORCE (Max duration)"))
    }

    @Test("Short speech below min_speech is discarded")
    func discardShortSpeech() {
        var c = AudioChunker()
        // 0.4s speech then 1.0s silence: speech_duration 0.4 ≤ 1.0 → discard.
        #expect(block(&c, seconds: 0.4, speech: true) == .continue)
        #expect(block(&c, seconds: 0.5, speech: false) == .continue)
        #expect(block(&c, seconds: 0.5, speech: false) == .discard)
    }

    @Test("Pure silence with no speech is discarded")
    func discardPureSilence() {
        var c = AudioChunker()
        #expect(block(&c, seconds: 0.5, speech: false) == .continue)
        #expect(block(&c, seconds: 0.5, speech: false) == .discard)
    }

    @Test("State resets after a trigger — next chunk is independent")
    func resetsAfterTrigger() {
        var c = AudioChunker()
        for _ in 0..<3 { _ = block(&c, seconds: 0.5, speech: true) }
        _ = block(&c, seconds: 0.5, speech: false)
        #expect(block(&c, seconds: 0.5, speech: false) == .emit(triggerType: "Normal"))
        // Fresh chunk: pure silence should not immediately emit the prior speech.
        #expect(block(&c, seconds: 0.5, speech: false) == .continue)
        #expect(block(&c, seconds: 0.5, speech: false) == .discard)
    }

    @Test("VAD-style multiple frames per block accumulate silence correctly")
    func multipleFramesPerBlock() {
        var c = AudioChunker()
        // One 0.9s block containing speech then trailing silence via 30ms frames.
        c.beginBlock(samples: Int(0.9 * Double(sr)))
        // 0.3s speech (10 frames) then 0.6s silence (20 frames).
        for _ in 0..<10 { c.voiceFrame(isSpeech: true, seconds: 0.03) }
        for _ in 0..<20 { c.voiceFrame(isSpeech: false, seconds: 0.03) }
        // silence_counter = 0.6 < 1.0 and duration 0.9 < 4 → continue.
        #expect(c.endBlock() == .continue)
    }

    @Test("Final chunk shorter than 0.3s is dropped")
    func finalChunkGuard() {
        let c = AudioChunker()
        #expect(c.shouldKeepFinalChunk(sampleCount: Int(0.2 * 16000)) == false)
        #expect(c.shouldKeepFinalChunk(sampleCount: Int(0.3 * 16000)) == true)
        #expect(c.shouldKeepFinalChunk(sampleCount: Int(1.0 * 16000)) == true)
    }
}

@Suite("RMSVoiceActivityDetector")
struct RMSVADTests {
    @Test("Silence (zeros) is not speech")
    func silence() {
        let vad = RMSVoiceActivityDetector()
        #expect(vad.isSpeech([Float](repeating: 0, count: 480)) == false)
    }

    @Test("Loud frame is speech")
    func speech() {
        let vad = RMSVoiceActivityDetector()
        #expect(vad.isSpeech([Float](repeating: 0.5, count: 480)) == true)
    }

    @Test("Threshold boundary")
    func boundary() {
        let vad = RMSVoiceActivityDetector(threshold: 0.01)
        // Constant amplitude 0.02 → rms 0.02 ≥ 0.01 → speech.
        #expect(vad.isSpeech([Float](repeating: 0.02, count: 100)) == true)
        // Amplitude 0.005 → rms 0.005 < 0.01 → silence.
        #expect(vad.isSpeech([Float](repeating: 0.005, count: 100)) == false)
    }

    @Test("Empty frame is silence")
    func empty() {
        #expect(RMSVoiceActivityDetector().isSpeech([]) == false)
    }
}

@Suite("SampleRingBuffer")
struct RingBufferTests {
    @Test("FIFO write then read")
    func fifo() {
        let rb = SampleRingBuffer(capacity: 10)
        rb.write([1, 2, 3])
        #expect(rb.availableCount == 3)
        #expect(rb.read(maxCount: 2) == [1, 2])
        #expect(rb.read(maxCount: 10) == [3])
        #expect(rb.availableCount == 0)
    }

    @Test("Wrap-around across capacity boundary")
    func wrapAround() {
        let rb = SampleRingBuffer(capacity: 4)
        rb.write([1, 2, 3])
        _ = rb.read(maxCount: 2)      // head now at index 2
        rb.write([4, 5, 6])           // wraps around
        #expect(rb.readAll() == [3, 4, 5, 6])
    }

    @Test("Overflow drops oldest samples")
    func overflow() {
        let rb = SampleRingBuffer(capacity: 3)
        let dropped = rb.write([1, 2, 3, 4, 5])
        #expect(dropped == 2)
        #expect(rb.readAll() == [3, 4, 5])
    }

    @Test("Clear empties the buffer")
    func clear() {
        let rb = SampleRingBuffer(capacity: 5)
        rb.write([1, 2, 3])
        rb.clear()
        #expect(rb.availableCount == 0)
        #expect(rb.readAll() == [])
    }

    @Test("Capacity from seconds")
    func capacitySeconds() {
        let rb = SampleRingBuffer(capacitySeconds: 2.0, sampleRate: 16000)
        rb.write([Float](repeating: 0, count: 40000)) // 2.5s worth
        #expect(rb.availableCount == 32000)            // capped at 2s
    }
}
