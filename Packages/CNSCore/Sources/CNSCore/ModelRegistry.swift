import Foundation

/// Describes a model that can be downloaded and used locally.
public struct ModelInfo: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let downloadURL: URL
    public let fileName: String
    /// Expected size in bytes (used for progress display before the server
    /// reports Content-Length).
    public let sizeEstimate: Int64
    public let kind: ModelKind

    public init(
        id: String,
        displayName: String,
        downloadURL: URL,
        fileName: String,
        sizeEstimate: Int64,
        kind: ModelKind
    ) {
        self.id = id
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.fileName = fileName
        self.sizeEstimate = sizeEstimate
        self.kind = kind
    }
}

public enum ModelKind: String, Sendable, Equatable {
    case whisper
    case aiEditor
}

/// Static lists of models the app knows how to download. URLs point at
/// single-file GGUF/BIN downloads on HuggingFace — no `snapshot_download`,
/// no repo clone, no `huggingface_hub` dependency.
public enum ModelRegistry {

    // MARK: - Whisper models (whisper.cpp GGML format)

    /// Direct-download links from `ggerganov/whisper.cpp` on HuggingFace.
    public static let whisperModels: [ModelInfo] = [
        ModelInfo(
            id: "whisper-large-v3-turbo",
            displayName: "Turbo",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            fileName: "ggml-large-v3-turbo.bin",
            sizeEstimate: 834_000_000,       // ~795 MB
            kind: .whisper
        ),
        ModelInfo(
            id: "whisper-large-v3",
            displayName: "Large v3",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
            fileName: "ggml-large-v3.bin",
            sizeEstimate: 1_550_000_000,     // ~1.5 GB
            kind: .whisper
        ),
        ModelInfo(
            id: "whisper-medium",
            displayName: "Medium",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            fileName: "ggml-medium.bin",
            sizeEstimate: 790_000_000,       // ~790 MB
            kind: .whisper
        ),
        ModelInfo(
            id: "whisper-small",
            displayName: "Small",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            fileName: "ggml-small.bin",
            sizeEstimate: 244_000_000,       // ~244 MB
            kind: .whisper
        ),
        ModelInfo(
            id: "whisper-base",
            displayName: "Base",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            fileName: "ggml-base.bin",
            sizeEstimate: 74_000_000,        // ~74 MB
            kind: .whisper
        ),
    ]

    // MARK: - AI Editor models (llama.cpp GGUF format)

    public static let aiEditorModels: [ModelInfo] = [
        ModelInfo(
            id: "qwen2.5-1.5b-q4",
            displayName: "Qwen 2.5 1.5B (Q4)",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            sizeEstimate: 1_050_000_000,     // ~1 GB
            kind: .aiEditor
        ),
    ]

    // MARK: - Defaults

    public static let defaultWhisperModelID = "whisper-large-v3-turbo"
    public static let defaultAiEditorModelID = "qwen2.5-1.5b-q4"

    // MARK: - Lookup

    public static func whisperModel(id: String) -> ModelInfo? {
        whisperModels.first { $0.id == id }
    }

    public static func aiEditorModel(id: String) -> ModelInfo? {
        aiEditorModels.first { $0.id == id }
    }

    /// Find any model by its id across all registries.
    public static func model(id: String) -> ModelInfo? {
        whisperModel(id: id) ?? aiEditorModel(id: id)
    }

    // MARK: - Legacy ID mapping

    /// Maps Python-era MLX model hub IDs (e.g. "mlx-community/whisper-large-v3-turbo")
    /// to the corresponding `ModelRegistry` ID used for GGML downloads.
    private static let legacyWhisperMap: [String: String] = [
        "mlx-community/whisper-large-v3-turbo": "whisper-large-v3-turbo",
        "mlx-community/whisper-large-v3-mlx":   "whisper-large-v3",
        "mlx-community/whisper-medium-mlx":     "whisper-medium",
        "mlx-community/whisper-small-mlx":      "whisper-small",
        "mlx-community/whisper-base-mlx":       "whisper-base",
    ]

    /// Resolve a Whisper model from either a `ModelRegistry` ID or a legacy
    /// MLX hub ID (from `ModelCatalog` / config.json `model_name`).
    public static func whisperModelByLegacyID(_ legacyID: String) -> ModelInfo? {
        let mapped = legacyWhisperMap[legacyID] ?? legacyID
        return whisperModel(id: mapped)
    }
}
