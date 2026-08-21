import Foundation
import Testing
@testable import CNSDictionary

@Suite("PhraseHistory")
struct PhraseHistoryTests {
    private func makeHistory() -> (PhraseHistory, URL, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cns-phrases-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("phrase_history.txt")
        return (PhraseHistory(fileURL: file), file, dir)
    }

    @Test("Phrases are appended as timestamp-TAB-text lines")
    func appendsTSV() throws {
        let (history, file, dir) = makeHistory()
        defer { try? FileManager.default.removeItem(at: dir) }

        history.append("первая фраза")
        history.append("вторая фраза")

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1)
            #expect(parts.count == 2)
            // 2026-07-23T09:15:00 — 19 characters, no timezone, as in Python.
            #expect(parts[0].count == 19)
        }
        #expect(lines[1].hasSuffix("вторая фраза"))
    }

    @Test("Newlines collapse to spaces and blank phrases are dropped")
    func normalizesText() throws {
        let (history, file, dir) = makeHistory()
        defer { try? FileManager.default.removeItem(at: dir) }

        history.append("  строка один\nстрока два  ")
        history.append("   ")
        history.append("")

        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.split(separator: "\n").count == 1)
        #expect(contents.hasSuffix("строка один строка два\n"))
    }

    @Test("Count is cached but stays correct across appends")
    func counts() {
        let (history, _, dir) = makeHistory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(history.count() == 0)
        history.append("одна")
        history.append("две")
        #expect(history.count() == 2)
    }

    @Test("Last phrases come back oldest-first with their timestamps")
    func readsLastPhrases() {
        let (history, _, dir) = makeHistory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 1...5 { history.append("фраза \(i)") }
        let last = history.lastPhrases(2)

        #expect(last.map(\.text) == ["фраза 4", "фраза 5"])
        #expect(last.allSatisfy { $0.timestamp.count == 19 })
    }

    @Test("A missing file reads as empty rather than failing")
    func handlesMissingFile() {
        let (history, _, dir) = makeHistory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(history.lastPhrases(3).isEmpty)
        #expect(history.count() == 0)
    }
}
