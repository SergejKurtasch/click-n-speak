import CNSCore
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

public protocol LocalTextGenerating: Sendable {
    func prepare() async throws
    func generate(systemPrompt: String, text: String, maximumTokens: Int) async throws -> String
    func stop() async
}

/// Production MLX Swift adapter. Models are loaded only from the app-managed
/// snapshot directory; the runtime never starts an implicit network download.
public actor MLXLocalTextGenerator: LocalTextGenerating {
    private let modelDirectory: URL
    private var container: ModelContainer?

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public func prepare() async throws {
        guard container == nil else { return }
        container = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
    }

    public func generate(systemPrompt: String, text: String, maximumTokens: Int) async throws -> String {
        guard let container else { throw LocalAiEditorError.notPrepared }
        let parameters = GenerateParameters(
            maxTokens: maximumTokens,
            temperature: 0
        )
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: parameters
        )
        return try await session.respond(to: "<speech>\n\(text)\n</speech>")
    }

    public func stop() async {
        container = nil
        Memory.clearCache()
    }
}

public enum LocalAiEditorError: LocalizedError, Sendable {
    case modelDirectoryMissing
    case modelSnapshotIncomplete(String)
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing:
            "The local AI editor model directory is missing"
        case let .modelSnapshotIncomplete(file):
            "The local AI editor model is missing \(file)"
        case .notPrepared:
            "The local AI editor has not been prepared"
        }
    }
}

public actor LocalAiEditor: AiEditing {
    public nonisolated let descriptor: AiEditorDescriptor
    private let readiness = LockedSnapshot(false)
    public nonisolated var isReady: Bool { readiness.get() }

    private let modelDirectory: URL
    private let gate: InferenceExecutionGate
    private let memoryPressure: any MemoryPressureProviding
    private let generator: any LocalTextGenerating
    private let realtimeWarmTimeout: TimeInterval
    private let realtimeColdTimeout: TimeInterval
    private let coldIdleThreshold: TimeInterval
    private let fileGateTimeout: TimeInterval
    private let fileOperationTimeout: TimeInterval
    private let fileMaximumChunkCharacters: Int
    private var lastCompletedAt: TimeInterval = 0

    public init(
        modelID: String,
        modelDirectory: URL,
        gate: InferenceExecutionGate,
        memoryPressure: any MemoryPressureProviding = MemoryPressureMonitor(),
        generator: (any LocalTextGenerating)? = nil,
        realtimeWarmTimeout: TimeInterval = EditorPolicy.realtimeWarmTimeout,
        realtimeColdTimeout: TimeInterval = EditorPolicy.realtimeColdTimeout,
        coldIdleThreshold: TimeInterval = EditorPolicy.coldIdleThreshold,
        fileGateTimeout: TimeInterval = EditorPolicy.fileGateTimeout,
        fileOperationTimeout: TimeInterval = EditorPolicy.fileOperationTimeout,
        fileMaximumChunkCharacters: Int = EditorPolicy.localMaximumFileChunkCharacters
    ) {
        self.modelDirectory = modelDirectory
        self.gate = gate
        self.memoryPressure = memoryPressure
        self.generator = generator ?? MLXLocalTextGenerator(modelDirectory: modelDirectory)
        self.realtimeWarmTimeout = realtimeWarmTimeout
        self.realtimeColdTimeout = realtimeColdTimeout
        self.coldIdleThreshold = coldIdleThreshold
        self.fileGateTimeout = fileGateTimeout
        self.fileOperationTimeout = fileOperationTimeout
        self.fileMaximumChunkCharacters = fileMaximumChunkCharacters
        self.descriptor = AiEditorDescriptor(backend: "local", modelID: modelID, kind: .local)
    }

    public func prepare() async throws {
        try Self.validateSnapshot(at: modelDirectory)
        try await generator.prepare()
        readiness.set(true)
    }

    public func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        _ = knownTerms
        _ = misrecognitions
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RefineResult(text: text, status: .disabled)
        }
        guard LocalEditorInputFilter.shouldRefine(text) else {
            return RefineResult(text: text, status: .skipped)
        }
        guard !memoryPressure.isHigh() else {
            return RefineResult(text: text, status: .memoryPressure)
        }
        guard let lease = gate.tryAcquire() else {
            return RefineResult(text: text, status: .skipped)
        }

        let generator = self.generator
        let prompt = AiEditorPrompts.buildSystemPrompt(languages: languages)
        let maximumTokens = EditorPolicy.realtimeMaximumOutputTokens(for: text)
        let operation = Task<RefineResult, Never> {
            defer { lease.release() }
            do {
                let output = try await generator.generate(
                    systemPrompt: prompt,
                    text: text,
                    maximumTokens: maximumTokens
                )
                return EditorPolicy.validatedOutput(output, original: text, multiplier: 2.5)
            } catch is CancellationError {
                return RefineResult(text: text, status: .timeout)
            } catch {
                return RefineResult(text: text, status: .error)
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        let timeout = now - lastCompletedAt > coldIdleThreshold
            ? realtimeColdTimeout
            : realtimeWarmTimeout
        let result = await AsyncDeadline.race(
            operation: operation,
            timeout: timeout,
            timeoutValue: RefineResult(text: text, status: .timeout)
        )
        if result.status == .ok || result.status == .unchanged {
            lastCompletedAt = ProcessInfo.processInfo.systemUptime
        }
        return result
    }

    public func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        _ = knownTerms
        _ = misrecognitions
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RefineResult(text: text, status: .disabled)
        }
        guard !memoryPressure.isHigh() else {
            return RefineResult(text: text, status: .memoryPressure)
        }

        let lease: InferenceExecutionLease
        do {
            guard let acquired = try await gate.acquire(timeout: fileGateTimeout) else {
                return RefineResult(text: text, status: .skipped)
            }
            lease = acquired
        } catch {
            return RefineResult(text: text, status: .skipped)
        }

        let chunks = EditorPolicy.splitAtSentenceBoundaries(
            text,
            maximumCharacters: fileMaximumChunkCharacters
        )
        let generator = self.generator
        let prompt = AiEditorPrompts.buildFileSystemPromptLocal(languages: languages)
        let operation = Task<RefineResult, Never> {
            defer { lease.release() }
            var refined: [String] = []
            for chunk in chunks {
                do {
                    try Task.checkCancellation()
                    let output = try await generator.generate(
                        systemPrompt: prompt,
                        text: chunk,
                        maximumTokens: EditorPolicy.fileMaximumOutputTokens(for: chunk)
                    )
                    let result = EditorPolicy.validatedOutput(output, original: chunk, multiplier: 2.5)
                    refined.append(result.status == .ok ? result.text : chunk)
                } catch is CancellationError {
                    return RefineResult(text: text, status: .timeout)
                } catch {
                    refined.append(chunk)
                }
            }
            let output = refined.joined(separator: "\n\n")
            return RefineResult(
                text: output,
                status: output == text ? .unchanged : .ok
            )
        }
        return await AsyncDeadline.race(
            operation: operation,
            timeout: fileOperationTimeout * Double(max(1, chunks.count)),
            timeoutValue: RefineResult(text: text, status: .timeout)
        )
    }

    public func stop() async {
        readiness.set(false)
        await generator.stop()
    }

    public static func validateSnapshot(at directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocalAiEditorError.modelDirectoryMissing
        }
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            let url = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LocalAiEditorError.modelSnapshotIncomplete(file)
            }
        }
    }
}

enum LocalEditorInputFilter {
    static func shouldRefine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count > 3 else { return false }
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return false }

        let normalized = words.map {
            $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        for index in 0..<max(0, normalized.count - 2) {
            let word = normalized[index]
            if !word.isEmpty, word == normalized[index + 1], word == normalized[index + 2] {
                return false
            }
        }
        return !trimmed.contains { character in
            if character.isWhitespace || character.isNumber || character.isASCII { return false }
            guard let scalar = character.unicodeScalars.first else { return true }
            return !(0x0400...0x052F).contains(Int(scalar.value))
        }
    }
}
