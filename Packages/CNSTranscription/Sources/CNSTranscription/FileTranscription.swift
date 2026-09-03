import Foundation

public enum FileMediaType: String, Sendable, Equatable {
    case wav
    case mp3
    case m4a
    case flac
    case aiff
    case mp4
    case mov
    case m4v

    public var mimeType: String {
        switch self {
        case .wav: "audio/wav"
        case .mp3: "audio/mpeg"
        case .m4a: "audio/mp4"
        case .flac: "audio/flac"
        case .aiff: "audio/aiff"
        case .mp4: "video/mp4"
        case .mov: "video/quicktime"
        case .m4v: "video/x-m4v"
        }
    }

    public static func detect(url: URL, header: Data? = nil) -> FileMediaType? {
        if let header {
            if header.starts(with: Data("RIFF".utf8)), header.count >= 12,
               String(data: header.subdata(in: 8..<12), encoding: .ascii) == "WAVE" { return .wav }
            if header.starts(with: Data("ID3".utf8)) || (header.count >= 2 && header[0] == 0xFF && header[1] & 0xE0 == 0xE0) { return .mp3 }
            if header.starts(with: Data("fLaC".utf8)) { return .flac }
            if header.starts(with: Data("FORM".utf8)) { return .aiff }
        }
        switch url.pathExtension.lowercased() {
        case "wav", "wave": return .wav
        case "mp3": return .mp3
        case "m4a", "aac": return .m4a
        case "flac": return .flac
        case "aif", "aiff": return .aiff
        case "mp4": return .mp4
        case "mov": return .mov
        case "m4v": return .m4v
        default: return nil
        }
    }
}

public enum FileTranscriptionStage: String, Sendable, Equatable {
    case preparing
    case decoding
    case transcribing
    case uploading
    case refining
    case completed
}

public struct FileTranscriptionProgress: Sendable, Equatable {
    public let stage: FileTranscriptionStage
    public let completedUnits: Int
    public let totalUnits: Int?

    public init(stage: FileTranscriptionStage, completedUnits: Int = 0, totalUnits: Int? = nil) {
        self.stage = stage
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }
}

public struct FileTranscriptionRequest: Sendable {
    public let url: URL
    public let initialPrompt: String?
    public let allowedLanguages: [String]
    public let refine: Bool

    public init(
        url: URL,
        initialPrompt: String? = nil,
        allowedLanguages: [String] = [],
        refine: Bool = false
    ) {
        self.url = url
        self.initialPrompt = initialPrompt
        self.allowedLanguages = allowedLanguages
        self.refine = refine
    }
}

public enum FileTranscriptionStatus: Sendable, Equatable {
    case success
    case noSpeech
    case cancelled
    case failed(TranscriptionFailure)
}

public struct FileTranscriptionResult: Sendable, Equatable {
    public var text: String
    public var detectedLanguage: String
    public var backend: String?
    public var modelID: String?
    public var status: FileTranscriptionStatus
    public var segmentCount: Int

    public init(
        text: String,
        detectedLanguage: String = "",
        backend: String? = nil,
        modelID: String? = nil,
        status: FileTranscriptionStatus,
        segmentCount: Int = 0
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.backend = backend
        self.modelID = modelID
        self.status = status
        self.segmentCount = segmentCount
    }

    public static func failed(_ failure: TranscriptionFailure) -> FileTranscriptionResult {
        FileTranscriptionResult(text: "", status: .failed(failure))
    }
}

public struct FileTranscriptionError: LocalizedError, Sendable {
    public let failure: TranscriptionFailure
    public var errorDescription: String? { failure.message }
}
