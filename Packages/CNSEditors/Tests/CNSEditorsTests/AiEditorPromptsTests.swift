import CryptoKit
import Foundation
import Testing
@testable import CNSEditors

private struct PromptGolden: Decodable {
    let realtimeEnSha256: String
    let fileRuSha256: String

    enum CodingKeys: String, CodingKey {
        case realtimeEnSha256 = "realtime_en_sha256"
        case fileRuSha256 = "file_ru_sha256"
    }
}

@Suite("AI editor prompt parity")
struct AiEditorPromptsTests {
    @Test("Swift prompt bytes match the Python golden hashes")
    func pythonGoldenHashes() throws {
        let url = try #require(Bundle.module.url(
            forResource: "prompt_golden",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let golden = try JSONDecoder().decode(PromptGolden.self, from: Data(contentsOf: url))

        let realtime = AiEditorPrompts.buildApiEditorSystemPrompt(
            languages: ["en"],
            knownTerms: ["Click-n-speak", "MLX"],
            misrecognitions: [("click and speak", "Click-n-speak")]
        )
        let file = AiEditorPrompts.buildFileSystemPromptGemini(
            languages: ["ru"],
            knownTerms: ["Cognee"],
            misrecognitions: [("когни", "Cognee")]
        )
        #expect(Self.sha256(realtime) == golden.realtimeEnSha256)
        #expect(Self.sha256(file) == golden.fileRuSha256)
    }

    @Test("Punctuation-only and multilingual requests retain conservative rules")
    func punctuationAndMultilingual() {
        let prompt = AiEditorPrompts.buildApiEditorSystemPrompt(
            languages: ["ru", "en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(prompt.contains("Russian and English"))
        #expect(prompt.contains("NEVER translate"))
        #expect(prompt.contains("'эм'"))
        #expect(prompt.contains("'um'"))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
