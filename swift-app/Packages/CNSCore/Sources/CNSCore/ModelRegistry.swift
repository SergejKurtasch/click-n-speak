import Foundation

/// A single immutable file in a versioned local-model release.
public struct ModelArtifact: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Codable {
        case ggml
        case safetensors
        case json
        case text
    }

    public let relativePath: String
    public let downloadURL: URL
    public let expectedSize: Int64
    public let sha256: String
    public let format: Format

    public init(
        relativePath: String,
        downloadURL: URL,
        expectedSize: Int64,
        sha256: String,
        format: Format
    ) {
        self.relativePath = relativePath
        self.downloadURL = downloadURL
        self.expectedSize = expectedSize
        self.sha256 = sha256.lowercased()
        self.format = format
    }
}

/// Describes a model that can be downloaded and used locally. Artifact data is
/// immutable and versioned with the application; runtime code never trusts
/// mutable repository branches.
public struct ModelInfo: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let downloadURL: URL
    public let fileName: String
    public let sizeEstimate: Int64
    public let kind: ModelKind
    public let storage: ModelStorage
    public let manifestVersion: Int
    public let sourceRevision: String
    public let artifacts: [ModelArtifact]
    public let minimumAppVersion: String?

    public init(
        id: String,
        displayName: String,
        downloadURL: URL,
        fileName: String,
        sizeEstimate: Int64,
        kind: ModelKind,
        storage: ModelStorage = .singleFile,
        manifestVersion: Int = ModelRegistry.manifestVersion,
        sourceRevision: String,
        artifacts: [ModelArtifact],
        minimumAppVersion: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.fileName = fileName
        self.sizeEstimate = sizeEstimate
        self.kind = kind
        self.storage = storage
        self.manifestVersion = manifestVersion
        self.sourceRevision = sourceRevision
        self.artifacts = artifacts
        self.minimumAppVersion = minimumAppVersion
    }
}

public enum ModelKind: String, Sendable, Equatable {
    case whisper
    case aiEditor
}

public enum ModelStorage: Sendable, Equatable {
    case singleFile
    case snapshot(repository: String, revision: String, requiredFiles: [String])
}

/// Static, cryptographically pinned model manifests. Hashes and byte counts are
/// copied from the upstream Hugging Face artifact metadata for the revisions
/// below and must be reviewed whenever `manifestVersion` changes.
public enum ModelRegistry {
    public static let manifestVersion = 1

    private static let whisperRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    private static let qwenRevision = "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"

    private static func whisper(
        id: String,
        displayName: String,
        fileName: String,
        size: Int64,
        sha256: String
    ) -> ModelInfo {
        let url = URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperRevision)/\(fileName)"
        )!
        return ModelInfo(
            id: id,
            displayName: displayName,
            downloadURL: url,
            fileName: fileName,
            sizeEstimate: size,
            kind: .whisper,
            sourceRevision: whisperRevision,
            artifacts: [
                ModelArtifact(
                    relativePath: fileName,
                    downloadURL: url,
                    expectedSize: size,
                    sha256: sha256,
                    format: .ggml
                ),
            ]
        )
    }

    public static let whisperModels: [ModelInfo] = [
        whisper(
            id: "whisper-large-v3-turbo",
            displayName: "Turbo",
            fileName: "ggml-large-v3-turbo.bin",
            size: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        ),
        whisper(
            id: "whisper-large-v3",
            displayName: "Large v3",
            fileName: "ggml-large-v3.bin",
            size: 3_095_033_483,
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        ),
        whisper(
            id: "whisper-medium",
            displayName: "Medium",
            fileName: "ggml-medium.bin",
            size: 1_533_763_059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        ),
        whisper(
            id: "whisper-small",
            displayName: "Small",
            fileName: "ggml-small.bin",
            size: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        ),
        whisper(
            id: "whisper-base",
            displayName: "Base",
            fileName: "ggml-base.bin",
            size: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        ),
    ]

    private static func qwenArtifact(
        _ path: String,
        size: Int64,
        sha256: String,
        format: ModelArtifact.Format
    ) -> ModelArtifact {
        ModelArtifact(
            relativePath: path,
            downloadURL: URL(
                string: "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit/resolve/\(qwenRevision)/\(path)"
            )!,
            expectedSize: size,
            sha256: sha256,
            format: format
        )
    }

    private static let qwenArtifacts: [ModelArtifact] = [
        qwenArtifact("added_tokens.json", size: 605, sha256: "58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b", format: .json),
        qwenArtifact("config.json", size: 784, sha256: "636d3e2a15e8914b8cf82b05cc2288a811f9bd93c3bf1afc00cab701a70b47c0", format: .json),
        qwenArtifact("merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5", format: .text),
        qwenArtifact("model.safetensors", size: 868_628_559, sha256: "0979f33d1bc58afcf696d13f57977644e7b11a6f0eec3e631d8e9463d18c0717", format: .safetensors),
        qwenArtifact("model.safetensors.index.json", size: 51_569, sha256: "6b98634d5044f0e2ad45228a374f8445904e571f1082392d08a6ce54f5d517ca", format: .json),
        qwenArtifact("special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", format: .json),
        qwenArtifact("tokenizer.json", size: 7_031_673, sha256: "a8506e7111b80c6d8635951a02eab0f4e1a8e4e5772da83846579e97b16f61bf", format: .json),
        qwenArtifact("tokenizer_config.json", size: 7_308, sha256: "f7c61e32b7a17d19bf8e7037dcb74079a833e53ea9801f24008cac68458f03b7", format: .json),
        qwenArtifact("vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", format: .json),
    ]

    public static let aiEditorModels: [ModelInfo] = [
        ModelInfo(
            id: "qwen2.5-1.5b-q4",
            displayName: "Qwen 2.5 1.5B (Q4)",
            downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit")!,
            fileName: "qwen2.5-1.5b-instruct-4bit",
            sizeEstimate: 880_169_797,
            kind: .aiEditor,
            storage: .snapshot(
                repository: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                revision: qwenRevision,
                requiredFiles: qwenArtifacts.map(\.relativePath)
            ),
            sourceRevision: qwenRevision,
            artifacts: qwenArtifacts
        ),
    ]

    public static let defaultWhisperModelID = "whisper-large-v3-turbo"
    public static let defaultAiEditorModelID = "qwen2.5-1.5b-q4"

    public static func whisperModel(id: String) -> ModelInfo? {
        whisperModels.first { $0.id == id }
    }

    public static func aiEditorModel(id: String) -> ModelInfo? {
        aiEditorModels.first { $0.id == id }
    }

    public static func model(id: String) -> ModelInfo? {
        whisperModel(id: id) ?? aiEditorModel(id: id)
    }

    private static let legacyWhisperMap: [String: String] = [
        "mlx-community/whisper-large-v3-turbo": "whisper-large-v3-turbo",
        "mlx-community/whisper-large-v3-mlx": "whisper-large-v3",
        "mlx-community/whisper-medium-mlx": "whisper-medium",
        "mlx-community/whisper-small-mlx": "whisper-small",
        "mlx-community/whisper-base-mlx": "whisper-base",
    ]

    public static func whisperModelByLegacyID(_ legacyID: String) -> ModelInfo? {
        whisperModel(id: legacyWhisperMap[legacyID] ?? legacyID)
    }
}
