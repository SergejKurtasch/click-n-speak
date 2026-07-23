import Testing
import Foundation
@testable import CNSTranscription

/// Real-engine tests. Gated on env vars because the model is 1.4 GB and lives
/// outside the repo — they run locally, skip in CI.
///   CNS_WHISPER_MODEL  path to ggml-large-v3-turbo.bin
///   CNS_WHISPER_WAV    path to a 16 kHz mono WAV to transcribe
@Suite("WhisperCppTranscriber (model-gated)")
struct WhisperCppTranscriberTests {
    private var modelURL: URL? {
        ProcessInfo.processInfo.environment["CNS_WHISPER_MODEL"].map { URL(fileURLWithPath: $0) }
    }
    private var wavURL: URL? {
        ProcessInfo.processInfo.environment["CNS_WHISPER_WAV"].map { URL(fileURLWithPath: $0) }
    }

    /// Read a 16 kHz mono 16-bit PCM WAV (walks RIFF chunks; afconvert emits
    /// WAVE_FORMAT_EXTENSIBLE which stdlib readers reject).
    private func readWav(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1])<<8 | Int(data[o+2])<<16 | Int(data[o+3])<<24 }
        var pos = 12
        var dataStart = -1, dataSize = 0
        while pos + 8 <= data.count {
            let id = String(bytes: data[pos..<pos+4], encoding: .ascii) ?? ""
            let size = u32(pos+4)
            if id == "data" { dataStart = pos+8; dataSize = min(size, data.count - dataStart); break }
            pos += 8 + size + (size & 1)
        }
        guard dataStart >= 0 else { throw NSError(domain: "wav", code: 1) }
        var out = [Float]()
        out.reserveCapacity(dataSize/2)
        var i = dataStart
        while i + 1 < dataStart + dataSize {
            let s = Int16(bitPattern: UInt16(data[i]) | UInt16(data[i+1]) << 8)
            out.append(Float(s) / 32768.0)
            i += 2
        }
        return out
    }

    @Test("Transcribes a golden WAV to non-empty Russian text",
          .enabled(if: ProcessInfo.processInfo.environment["CNS_WHISPER_MODEL"] != nil
                       && ProcessInfo.processInfo.environment["CNS_WHISPER_WAV"] != nil))
    func realDecode() async throws {
        let audio = try readWav(wavURL!)
        let engine = WhisperCppTranscriber(modelURL: modelURL!)
        let result = await engine.transcribe(
            TranscriptionRequest(audio: audio, allowedLanguages: ["ru"], isFinalChunk: true))
        await engine.stop()

        #expect(!result.text.isEmpty)
        #expect(result.detectedLanguage == "ru")
        // The golden WAVs are short dictation commands; sanity-check length.
        #expect(result.text.count > 3)
        print("whisper.cpp decode → \(result.text)")
    }
}
