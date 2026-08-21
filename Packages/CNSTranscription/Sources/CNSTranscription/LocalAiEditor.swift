import Foundation
import CNSCore

/// Stub for the local LLM editor using llama.cpp.
/// Full integration (C-interop with llama.cpp xcframework) will be done in a separate PR.
public actor LocalAiEditor: AiEditing {
    public let isReady: Bool
    private let modelPath: URL
    
    public init(modelName: String, paths: Paths) {
        let model = ModelRegistry.aiEditorModel(id: modelName)
            ?? ModelInfo(
                id: modelName,
                displayName: "Local",
                downloadURL: URL(string: "https://localhost")!,
                fileName: modelName,
                sizeEstimate: 0,
                kind: .aiEditor
            )
        self.modelPath = paths.modelFile(for: model)
        self.isReady = FileManager.default.fileExists(atPath: modelPath.path)
    }
    
    public func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        guard isReady else {
            return RefineResult(text: text, status: .disabled)
        }
        // Stub implementation: returns unchanged text.
        return RefineResult(text: text, status: .unchanged)
    }
    
    public func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        guard isReady else {
            return RefineResult(text: text, status: .disabled)
        }
        // Stub implementation: returns unchanged text.
        return RefineResult(text: text, status: .unchanged)
    }
}
