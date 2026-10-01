import Foundation

/// Static model lists shown in the Model menu. Mirrors the constants in
/// `menu_bar.py` (`WHISPER_MODELS`, `WHISPER_MODEL_SIZES`) and
/// `cloud_transcriber.py` (`CLOUD_STT_MODELS`, `DEFAULT_CLOUD_STT_MODEL`).
public enum ModelCatalog {
    public struct Model: Sendable, Equatable {
        public let label: String
        public let id: String
    }

    /// Local Whisper models, in menu order.
    public static let whisperModels: [Model] = [
        Model(label: "Turbo", id: "mlx-community/whisper-large-v3-turbo"),
        Model(label: "Large v3", id: "mlx-community/whisper-large-v3-mlx"),
        Model(label: "Medium", id: "mlx-community/whisper-medium-mlx"),
        Model(label: "Small", id: "mlx-community/whisper-small-mlx"),
        Model(label: "Base", id: "mlx-community/whisper-base-mlx"),
    ]

    /// Approximate download sizes shown next to each local model.
    public static let whisperModelSizes: [String: String] = [
        "mlx-community/whisper-large-v3-turbo": "~795 MB",
        "mlx-community/whisper-large-v3-mlx": "~1.5 GB",
        "mlx-community/whisper-medium-mlx": "~790 MB",
        "mlx-community/whisper-small-mlx": "~244 MB",
        "mlx-community/whisper-base-mlx": "~74 MB",
    ]

    /// Cloud STT models by backend, in menu order.
    public static let cloudSTTModels: [(backend: String, models: [Model])] = [
        ("gemini", [
            Model(label: "Gemini 2.5 Flash-Lite", id: "gemini-2.5-flash-lite"),
            Model(label: "Gemini 2.5 Flash", id: "gemini-2.5-flash"),
            Model(label: "Gemini 3 Flash", id: "gemini-3-flash"),
        ]),
        ("openai", [
            Model(label: "GPT-4o mini Transcribe", id: "gpt-4o-mini-transcribe"),
            Model(label: "GPT-4o Transcribe", id: "gpt-4o-transcribe"),
            Model(label: "Whisper-1", id: "whisper-1"),
        ]),
    ]

    public static let defaultCloudSTTModel = "gemini-2.5-flash-lite"
    public static let defaultWhisperModel = "mlx-community/whisper-large-v3-turbo"

    public static func size(for modelID: String) -> String {
        whisperModelSizes[modelID] ?? "?"
    }
}
