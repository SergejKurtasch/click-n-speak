import CNSCore
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

    @Test("Append provenance serializes every runtime segment without changing legacy records")
    func serializesSegments() throws {
        let record = DatasetRecord(
            rawWhisper: "first second",
            aiEdited: nil,
            userFinal: "corrected first second",
            segments: [
                DatasetSegment(
                    rawWhisper: "first",
                    aiEdited: nil,
                    aiStatus: "disabled",
                    runtime: RuntimeDescriptor(
                        transcriber: .init(backend: "local", modelID: "whisper-a", kind: .local),
                        aiEditor: .disabled
                    ),
                    promptHash: "prompt-a"
                ),
                DatasetSegment(
                    rawWhisper: "second",
                    aiEdited: "second edited",
                    aiStatus: "ok",
                    runtime: RuntimeDescriptor(
                        transcriber: .init(backend: "openai", modelID: "gpt-4o-transcribe", kind: .cloud),
                        aiEditor: .init(backend: "gemini", modelID: "flash", kind: .cloud)
                    ),
                    promptHash: "prompt-b"
                ),
            ]
        )

        let line = DatasetLogger.jsonLine(record, at: date("2026-07-23T10:00:00Z"))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let segments = try #require(object["segments"] as? [[String: Any]])

        #expect(segments.count == 2)
        #expect(segments[0]["raw_whisper"] as? String == "first")
        #expect(segments[0]["stt_model"] as? String == "whisper-a")
        #expect(segments[1]["ai_edited"] as? String == "second edited")
        #expect(segments[1]["ai_backend"] as? String == "gemini")
        #expect(segments[1]["prompt_hash"] as? String == "prompt-b")

        let legacy = DatasetLogger.jsonLine(
            DatasetRecord(rawWhisper: "one", userFinal: "one"),
            at: date("2026-07-23T10:00:00Z")
        )
        let legacyObject = try #require(
            JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any]
        )
        #expect(legacyObject["segments"] == nil)
    }

    @Test("Only incomplete confirmations add the compatibility-safe marker")
    func serializesIncompleteMarker() throws {
        let incomplete = DatasetLogger.jsonLine(
            DatasetRecord(rawWhisper: "first third", userFinal: "first third", incomplete: true),
            at: date("2026-07-23T10:00:00Z")
        )
        let incompleteObject = try #require(
            JSONSerialization.jsonObject(with: Data(incomplete.utf8)) as? [String: Any]
        )
        #expect(incompleteObject["incomplete"] as? Bool == true)

        let complete = DatasetLogger.jsonLine(
            DatasetRecord(rawWhisper: "whole", userFinal: "whole"),
            at: date("2026-07-23T10:00:00Z")
        )
        let completeObject = try #require(
            JSONSerialization.jsonObject(with: Data(complete.utf8)) as? [String: Any]
        )
        #expect(completeObject["incomplete"] == nil)
    }
}
