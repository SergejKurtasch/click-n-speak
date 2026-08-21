import Testing
@testable import CNSTranscription

@Suite("GeminiEditor")
struct GeminiEditorTests {
    @Test("Initialization")
    func testInitialization() {
        let editor = GeminiEditor(modelName: "gemini-test", apiKey: "test-key")
        #expect(editor != nil)
    }
}
