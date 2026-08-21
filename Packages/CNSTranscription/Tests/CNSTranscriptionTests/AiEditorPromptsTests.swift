import XTesting
import Testing
@testable import CNSTranscription

@Suite("AiEditorPrompts")
struct AiEditorPromptsTests {
    @Test("Chunk context prompt contains vocab hints")
    func testChunkContextPrompt() {
        let vocab = ["test1", "test2"]
        let prompt = AiEditorPrompts.buildChunkContext(vocab: vocab, lang: "en")
        
        #expect(prompt.contains("test1"))
        #expect(prompt.contains("test2"))
        #expect(prompt.contains("Click-n-speak"))
    }
    
    @Test("Gemini system instruction contains file prompt and hints")
    func testGeminiSystemInstruction() {
        let vocab = ["apple", "banana"]
        let prompt = AiEditorPrompts.buildGeminiSystemInstruction(vocab: vocab, isFile: true, lang: "ru")
        
        #expect(prompt.contains("apple"))
        #expect(prompt.contains("banana"))
        #expect(prompt.contains("Russian"))
        // File prompt should be used
        #expect(prompt.contains("document"))
    }
}
