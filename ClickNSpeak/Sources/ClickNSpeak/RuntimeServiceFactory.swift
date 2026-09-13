import CNSCore
import CNSEditors
import CNSTranscription
import Foundation

protocol CredentialProviding: Sendable {
    func password(service: String, account: String) -> String?
}

struct KeychainCredentialProvider: CredentialProviding {
    func password(service: String, account: String) -> String? {
        KeychainHelper.getPassword(service: service, account: account)
    }
}

enum RuntimePreparationError: LocalizedError, Sendable, Equatable {
    case modelMissing(modelID: String)
    case modelCorrupted(modelID: String)
    case credentialMissing(backend: String)
    case unsupportedBackend(String)
    case unsupportedModel(String)
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .modelMissing(id): "Local model is not downloaded: \(id)"
        case let .modelCorrupted(id): "Local model is incomplete or corrupted: \(id)"
        case let .credentialMissing(backend): "API key is missing for \(backend)"
        case let .unsupportedBackend(backend): "Unsupported runtime backend: \(backend)"
        case let .unsupportedModel(id): "Unsupported model: \(id)"
        case let .initializationFailed(message): "Runtime initialization failed: \(message)"
        }
    }
}

struct PreparedTranscriber: Sendable {
    let service: any Transcribing
    let descriptor: TranscriberDescriptor
}

struct PreparedEditor: Sendable {
    let service: (any AiEditing)?
    let descriptor: AiEditorDescriptor
}


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
}

protocol RuntimeServiceBuilding: Sendable {
    func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber
    func prepareEditor(config: Config, generation: Int) async throws -> PreparedEditor
}

/// The sole production construction path for inference services. It validates
/// prerequisites and never substitutes a stub for a failed backend.
struct RuntimeServiceFactory: RuntimeServiceBuilding, Sendable {
    private let paths: Paths
    private let credentials: any CredentialProviding
    private let log: @Sendable (String) -> Void
    private let localModelOverride: URL?
    private let localEditorModelOverride: URL?
    private let inferenceGate: InferenceExecutionGate

    init(
        paths: Paths,
        credentials: any CredentialProviding = KeychainCredentialProvider(),
        localModelOverride: URL? = nil,
        localEditorModelOverride: URL? = nil,
        inferenceGate: InferenceExecutionGate = InferenceExecutionGate(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.paths = paths
        self.credentials = credentials
        self.localModelOverride = localModelOverride
        self.localEditorModelOverride = localEditorModelOverride
        self.inferenceGate = inferenceGate
        self.log = log
    }

    func prepareTranscriber(config: Config, generation: Int) async throws -> PreparedTranscriber {
        let registry = ModelArtifactAccessRegistry.shared
        switch config.sttBackend {
        case "local":
            let requestedID = config.sttModelName
            guard let model = ModelRegistry.whisperModelByLegacyID(requestedID) else {
                throw RuntimePreparationError.unsupportedModel(requestedID)
            }
            let modelURL = localModelOverride ?? paths.modelFile(for: model)
            if localModelOverride == nil {
                do {
                    try await ModelManager.validate(model, paths: paths)
                } catch let error as ModelValidationError {
                    if case .missingArtifact = error {
                        throw RuntimePreparationError.modelMissing(modelID: model.id)
                    }
                    throw RuntimePreparationError.modelCorrupted(modelID: model.id)
                }
            } else {
                try validateTestOverride(modelURL, modelID: model.id)
            }

            var token: UUID? = nil
            if localModelOverride == nil {
                do {
                    token = try registry.acquireUse(modelID: model.id, reason: ModelArtifactUse.preparation(generation: generation))
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
                registry.updateReason(t, reason: ModelArtifactUse.activeRuntime(descriptor: RuntimeDescriptor(transcriber: TranscriberDescriptor(backend: "local", modelID: model.id, kind: .local), aiEditor: .disabled)))
            }
            log("Prepared local STT runtime: \(model.id)")
            return PreparedTranscriber(
                service: service,
                descriptor: TranscriberDescriptor(
                    backend: "local", modelID: model.id, kind: .local
                )
            )

        case "gemini", "openai":
            let backendName = config.sttBackend
            guard let backend = CloudSTTBackend(rawValue: backendName) else {
                throw RuntimePreparationError.unsupportedBackend(backendName)
            }
            let account = backend == .gemini
                ? KeychainHelper.geminiAccount
                : KeychainHelper.openAIAccount
            guard let key = credentials.password(service: KeychainHelper.defaultService, account: account) else {
                throw RuntimePreparationError.credentialMissing(backend: backendName)
            }
            let modelID = config.raw["stt_cloud_model"]?.stringValue
                ?? (backend == .gemini ? "gemini-2.5-flash-lite" : "gpt-4o-mini-transcribe")
            let service: any Transcribing = GuardedTranscriber(
                wrapping: CloudSTTTranscriber(backend: backend, modelName: modelID, apiKey: key)
            )
            try await service.prepare(language: config.primaryLanguage)
            log("Prepared cloud STT runtime: \(backendName)/\(modelID)")
            return PreparedTranscriber(
                service: service,
                descriptor: TranscriberDescriptor(
                    backend: backendName, modelID: modelID, kind: .cloud
                )
            )

        default:
            throw RuntimePreparationError.unsupportedBackend(config.sttBackend)
        }
    }

    func prepareEditor(config: Config, generation: Int) async throws -> PreparedEditor {
        let registry = ModelArtifactAccessRegistry.shared
guard config.aiEditorEnabled else {
            return PreparedEditor(service: nil, descriptor: .disabled)
        }

        switch config.aiEditorBackend {
        case "local":
            let requestedID = normalizedEditorModelID(config.aiEditorModel)
            guard let model = ModelRegistry.aiEditorModel(id: requestedID) else {
                throw RuntimePreparationError.unsupportedModel(requestedID)
            }
            let modelDirectory = localEditorModelOverride ?? paths.modelFile(for: model)
            if localEditorModelOverride == nil {
                do {
                    try await ModelManager.validate(model, paths: paths)
                } catch let error as ModelValidationError {
                    if case .missingArtifact = error {
                        throw RuntimePreparationError.modelMissing(modelID: model.id)
                    }
                    throw RuntimePreparationError.modelCorrupted(modelID: model.id)
                }
            }
            var token: UUID? = nil
            if localEditorModelOverride == nil {
                do {
                    token = try registry.acquireUse(modelID: model.id, reason: ModelArtifactUse.preparation(generation: generation))
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
                registry.updateReason(t, reason: ModelArtifactUse.activeRuntime(descriptor: RuntimeDescriptor(
                    transcriber: .unavailable,
                    aiEditor: editor.descriptor
                )))
            }
            guard editor.isReady else {
                throw RuntimePreparationError.initializationFailed("Local editor is not ready")
            }
            return PreparedEditor(
                service: editor,
                descriptor: editor.descriptor
            )

        case "gemini":
            guard let key = credentials.password(
                service: KeychainHelper.defaultService,
                account: KeychainHelper.geminiAccount
            ) else {
                throw RuntimePreparationError.credentialMissing(backend: "gemini")
            }
            let editor = GeminiEditor(modelName: config.geminiModel, apiKey: key)
            try await editor.prepare()
            return PreparedEditor(
                service: editor,
                descriptor: editor.descriptor
            )

        default:
            throw RuntimePreparationError.unsupportedBackend(config.aiEditorBackend)
        }
    }

    /// Test-only dependency overrides are intentionally outside the production
    /// registry and therefore receive the lightweight fixture validation.
    private func validateTestOverride(_ url: URL, modelID: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimePreparationError.modelMissing(modelID: modelID)
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 1_000_000 else {
            throw RuntimePreparationError.modelCorrupted(modelID: modelID)
        }
    }

    private func normalizedEditorModelID(_ value: String) -> String {
        if value == "mlx-community/Qwen2.5-1.5B-Instruct-4bit" {
            return ModelRegistry.defaultAiEditorModelID
        }
        return value
    }
}
