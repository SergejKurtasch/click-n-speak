import Foundation
import Testing
@testable import CNSDictionary

@Suite("DatasetLogger")
struct DatasetLoggerTests {
    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test("Terms found in text match the Python _find_terms")
    func findsTerms() {
        let found = DatasetLogger.findTerms(
            in: "Мы используем Whisper и machine learning в C++",
            terms: ["whisper", "machine learning", "C++", "pytorch"]
        )
        // Real Python output for the same input.
        #expect(found == ["c++", "machine learning", "whisper"])
    }

    @Test("Empty text or empty dictionary yields nothing")
    func findsNothing() {
        #expect(DatasetLogger.findTerms(in: "", terms: ["a"]).isEmpty)
        #expect(DatasetLogger.findTerms(in: "текст", terms: []).isEmpty)
    }

    @Test("A record serializes exactly like json.dumps(ensure_ascii=False)")
    func matchesPythonJSON() {
        let record = DatasetRecord(
            rawWhisper: "привет \"мир\"",
            aiEdited: nil,
            aiStatus: nil,
            sttBackend: "local",
            sttModel: "m",
            aiModel: nil,
            userFinal: "привет мир",
            lang: "ru",
            promptHash: "abc",
            userTerms: ["мир"]
        )
        let line = DatasetLogger.jsonLine(record, at: date("2026-07-23T10:00:00Z"))

        #expect(line == #"{"timestamp": "2026-07-23T10:00:00+00:00", "raw_whisper": "привет \"мир\"", "ai_edited": null, "ai_status": null, "stt_backend": "local", "stt_model": "m", "ai_model": null, "user_final": "привет мир", "lang": "ru", "prompt_hash": "abc", "vocab_terms_in_raw": ["мир"], "vocab_terms_in_final": ["мир"]}"#)
    }

    @Test("Records append one line each and stay parseable")
    func appendsLines() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cns-dataset-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("dataset.jsonl")
        let logger = DatasetLogger(fileURL: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        logger.append(DatasetRecord(rawWhisper: "один", userFinal: "один"))
        logger.append(DatasetRecord(rawWhisper: "два", userFinal: "два"))

        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
        }
    }
}
