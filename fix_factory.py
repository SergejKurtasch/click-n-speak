import sys

with open("ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift", "r") as f:
    content = f.read()

new_structs = """
struct AccessTokenReleasingTranscriber: Transcribing {
    let inner: any Transcribing
    let tokens: [UUID]
    
    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult { await inner.transcribe(request) }
    func warmup(language: String?) async { await inner.warmup(language: language) }
    func prepare(language: String?) async throws { try await inner.prepare(language: language) }
    func preWarm() async -> PrewarmResult { await inner.preWarm() }
    func stop() async {
        await inner.stop()
        for token in tokens { ModelArtifactAccessRegistry.shared.releaseUse(token) }
    }
    func reload() async { await inner.reload() }
    nonisolated func abortInFlight() { inner.abortInFlight() }
    func tokenCount(_ text: String) async -> Int? { await inner.tokenCount(text) }
    func transcribeFile(_ request: FileTranscriptionRequest, progress: @escaping @Sendable (FileTranscriptionProgress) -> Void) async -> FileTranscriptionResult {
        await inner.transcribeFile(request, progress: progress)
    }
}

struct AccessTokenReleasingEditor: AiEditing {
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
}
"""

# Insert new_structs before `protocol RuntimeServiceBuilding`
content = content.replace("protocol RuntimeServiceBuilding: Sendable {", new_structs + "\nprotocol RuntimeServiceBuilding: Sendable {")

# Update protocol
content = content.replace("func prepareTranscriber(config: Config) async throws -> PreparedTranscriber", "func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber")
content = content.replace("func prepareEditor(config: Config) async throws -> PreparedEditor", "func prepareEditor(config: Config, generation: Int) async throws -> PreparedEditor")

# Update implementation
old_impl_t = "func prepareTranscriber(config: Config) async throws -> PreparedTranscriber {"
new_impl_t = """    func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber {
        let registry = ModelArtifactAccessRegistry.shared"""
content = content.replace(old_impl_t, new_impl_t)

old_local_stt_prep = """            let service: any Transcribing = GuardedTranscriber(
                wrapping: WhisperCppTranscriber(
                    modelURL: modelURL,
                    modelID: model.id,
                    inferenceGate: inferenceGate
                )
            )
            do {
                try await service.prepare(language: config.primaryLanguage)
            } catch {
                await service.stop()
                throw RuntimePreparationError.initializationFailed(error.localizedDescription)
            }"""

new_local_stt_prep = """            var token: UUID? = nil
            if localModelOverride == nil {
                do {
                    token = try registry.acquireUse(modelID: model.id, reason: .preparation(generation: generation))
                } catch {
                    throw RuntimePreparationError.initializationFailed(error.localizedDescription)
                }
            }
            
            let baseService: any Transcribing = GuardedTranscriber(
                wrapping: WhisperCppTranscriber(
                    modelURL: modelURL,
                    modelID: model.id,
                    inferenceGate: inferenceGate
                )
            )
            let service: any Transcribing = AccessTokenReleasingTranscriber(
                inner: baseService, 
                tokens: token.map { [$0] } ?? []
            )
            
            do {
                try await service.prepare(language: config.primaryLanguage)
            } catch {
                await service.stop()
                throw RuntimePreparationError.initializationFailed(error.localizedDescription)
            }
            
            if let t = token {
                registry.updateReason(t, reason: .activeRuntime(descriptor: TranscriberDescriptor(backend: "local", modelID: model.id, kind: .local)))
            }"""
content = content.replace(old_local_stt_prep, new_local_stt_prep)

old_impl_e = "func prepareEditor(config: Config) async throws -> PreparedEditor {"
new_impl_e = """    func prepareEditor(config: Config, generation: Int) async throws -> PreparedEditor {
        let registry = ModelArtifactAccessRegistry.shared"""
content = content.replace(old_impl_e, new_impl_e)

old_local_editor_prep = """            let editor = LocalAiEditor(
                modelID: model.id,
                modelDirectory: modelDirectory,
                gate: inferenceGate
            )
            do {
                try await editor.prepare()
            } catch {
                await editor.stop()
                throw RuntimePreparationError.initializationFailed(error.localizedDescription)
            }"""

new_local_editor_prep = """            var token: UUID? = nil
            if localEditorModelOverride == nil {
                do {
                    token = try registry.acquireUse(modelID: model.id, reason: .preparation(generation: generation))
                } catch {
                    throw RuntimePreparationError.initializationFailed(error.localizedDescription)
                }
            }

            let baseEditor = LocalAiEditor(
                modelID: model.id,
                modelDirectory: modelDirectory,
                gate: inferenceGate
            )
            let editor = AccessTokenReleasingEditor(
                inner: baseEditor,
                tokens: token.map { [$0] } ?? []
            )

            do {
                try await editor.prepare()
            } catch {
                await editor.stop()
                throw RuntimePreparationError.initializationFailed(error.localizedDescription)
            }
            
            if let t = token {
                registry.updateReason(t, reason: .activeRuntime(descriptor: RuntimeDescriptor(
                    transcriber: .unavailable,
                    aiEditor: editor.descriptor
                )))
            }"""
content = content.replace(old_local_editor_prep, new_local_editor_prep)

with open("ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift", "w") as f:
    f.write(content)
