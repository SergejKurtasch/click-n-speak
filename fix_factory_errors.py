import sys
import re

with open("ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift", "r") as f:
    content = f.read()

# fix AccessTokenReleasingEditor
old_editor = """struct AccessTokenReleasingEditor: AiEditing {
    let inner: any AiEditing
    let tokens: [UUID]
    
    var descriptor: AiEditorDescriptor { inner.descriptor }
    var isReady: Bool { inner.isReady }
    func prepare() async throws { try await inner.prepare() }
    func refine(_ request: RefinementRequest) async -> RefinementResult { await inner.refine(request) }
    func stop() async {
        await inner.stop()
        for token in tokens { ModelArtifactAccessRegistry.shared.releaseUse(token) }
    }
    nonisolated func abortInFlight() { inner.abortInFlight() }
    func tokenCount(_ text: String) async -> Int? { await inner.tokenCount(text) }
}"""
new_editor = """struct AccessTokenReleasingEditor: AiEditing {
    let inner: any AiEditing
    let tokens: [UUID]
    
    var descriptor: AiEditorDescriptor { inner.descriptor }
    var isReady: Bool { inner.isReady }
    func prepare() async throws { try await inner.prepare() }
    func refine(text: String, languages: [String]?, knownTerms: [String]?, misrecognitions: [(String, String)]?) async -> RefineResult {
        await inner.refine(text: text, languages: languages, knownTerms: knownTerms, misrecognitions: misrecognitions)
    }
    func refineFileText(text: String, languages: [String]?, knownTerms: [String]?, misrecognitions: [(String, String)]?) async -> RefineResult {
        await inner.refineFileText(text: text, languages: languages, knownTerms: knownTerms, misrecognitions: misrecognitions)
    }
    func stop() async {
        await inner.stop()
        for token in tokens { ModelArtifactAccessRegistry.shared.releaseUse(token) }
    }
}"""
content = content.replace(old_editor, new_editor)

# fix registry reference in prepareTranscriber and prepareEditor
# wait, did I put `let registry = ...` in prepareTranscriber?
content = content.replace("func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber {", "func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber {\n        let registry = ModelArtifactAccessRegistry.shared")
# wait, if it was already there, this will duplicate it. Let's use regex to replace safely.
content = re.sub(r'func prepareTranscriber\(config: Config, generation: Int\) async throws -> PreparedTranscriber \{\s*(let registry = ModelArtifactAccessRegistry\.shared\n)?', 'func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber {\n        let registry = ModelArtifactAccessRegistry.shared\n', content, count=1)
content = re.sub(r'func prepareEditor\(config: Config, generation: Int\) async throws -> PreparedEditor \{\s*(let registry = ModelArtifactAccessRegistry\.shared\n)?', 'func prepareEditor(config: Config, generation: Int) async throws -> PreparedEditor {\n        let registry = ModelArtifactAccessRegistry.shared\n', content, count=1)

with open("ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift", "w") as f:
    f.write(content)
