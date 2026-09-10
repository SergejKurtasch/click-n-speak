import Testing
@testable import CNSAudio

@Suite("AudioRecorder lifecycle validation")
struct AudioRecorderLifecycleTests {
    @Test("Invalid input dimensions fail before installing a tap")
    func invalidInputFormat() {
        #expect(throws: AudioRecorderError.invalidInputFormat(sampleRate: 0, channels: 0)) {
            try AudioRecorder.validateInputFormat(sampleRate: 0, channels: 0)
        }
        #expect(throws: AudioRecorderError.invalidInputFormat(sampleRate: 48_000, channels: 0)) {
            try AudioRecorder.validateInputFormat(sampleRate: 48_000, channels: 0)
        }
    }

    @Test("A positive sample rate and channel count are accepted")
    func validInputFormat() {
        #expect(throws: Never.self) {
            try AudioRecorder.validateInputFormat(sampleRate: 48_000, channels: 2)
        }
    }
}
