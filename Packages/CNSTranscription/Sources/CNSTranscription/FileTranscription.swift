import Foundation

public enum FileMediaType: String, Sendable, Equatable, Hashable, CaseIterable {
    case wav
    case mp3
    case m4a
    case aac
    case flac
    case aiff
    case caf
    case ogg
    case opus
    case mp4
    case mov
    case m4v

    public var mimeType: String {
        switch self {
        case .wav: "audio/wav"
        case .mp3: "audio/mpeg"
        case .m4a: "audio/mp4"
        case .aac: "audio/aac"
        case .flac: "audio/flac"
        case .aiff: "audio/aiff"
        case .caf: "audio/x-caf"
        case .ogg: "audio/ogg"
        case .opus: "audio/ogg"
        case .mp4: "video/mp4"
        case .mov: "video/quicktime"
        case .m4v: "video/x-m4v"
        }
    }

    public static func detect(url: URL, header: Data? = nil) -> FileMediaType? {
        if let header {
            guard !header.isEmpty else { return nil }
            if header.starts(with: Data("RIFF".utf8)), header.count >= 12,
               String(data: header.subdata(in: 8..<12), encoding: .ascii) == "WAVE" { return .wav }
            if header.starts(with: Data("caff".utf8)) { return .caf }
            if header.starts(with: Data("OggS".utf8)) {
                return header.range(of: Data("OpusHead".utf8)) == nil ? .ogg : .opus
            }
            if header.count >= 2, header[0] == 0xFF, header[1] & 0xF6 == 0xF0 { return .aac }
            if header.starts(with: Data("ID3".utf8)) || Self.hasMPEGFrameSync(header) { return .mp3 }
            if header.starts(with: Data("fLaC".utf8)) { return .flac }
            if header.starts(with: Data("FORM".utf8)) { return .aiff }
            if header.count >= 12,
               String(data: header.subdata(in: 4..<8), encoding: .ascii) == "ftyp" {
                switch String(data: header.subdata(in: 8..<12), encoding: .ascii) {
                case "M4A ", "M4B ": return .m4a
                case "qt  ": return .mov
                case "M4V ": return .m4v
                default: return .mp4
                }
            }
            return nil
        }
        switch url.pathExtension.lowercased() {
        case "wav", "wave": return .wav
        case "mp3": return .mp3
        case "m4a": return .m4a
        case "aac", "adts": return .aac
        case "flac": return .flac
        case "aif", "aiff": return .aiff
        case "caf", "caff": return .caf
        case "ogg", "oga": return .ogg
        case "opus": return .opus
        case "mp4": return .mp4
        case "mov": return .mov
        case "m4v": return .m4v
        default: return nil
        }
    }

    private static func hasMPEGFrameSync(_ header: Data) -> Bool {
        guard header.count >= 2, header[0] == 0xFF, header[1] & 0xE0 == 0xE0 else {
            return false
        }
        return header[1] & 0x06 != 0
    }
}

public enum MediaFormatPolicy: String, Sendable, Equatable {
    case nativeDecode
    case coreAudioConversion
    case unsupported
}

public enum MediaFormatCapabilities {
    public static let supportedExtensions = [
        "wav", "wave", "mp3", "m4a", "aac", "adts", "flac", "caf", "caff",
        "aif", "aiff", "mp4", "mov", "m4v"
    ]
    public static let displayExtensions = [
        "wav", "mp3", "m4a", "aac", "flac", "caf", "aiff", "mp4", "mov", "m4v"
    ]

    public static func policy(for mediaType: FileMediaType) -> MediaFormatPolicy {
        switch mediaType {
        case .aac:
            return .coreAudioConversion
        case .ogg, .opus:
            return .unsupported
        case .wav, .mp3, .m4a, .flac, .aiff, .caf, .mp4, .mov, .m4v:
            return .nativeDecode
        }
    }

    public static func supports(_ url: URL) -> Bool {
        guard let mediaType = FileMediaType.detect(url: url) else { return false }
        return policy(for: mediaType) != .unsupported
    }

    static func supportsDirectProviderUpload(_ mediaType: FileMediaType) -> Bool {
        switch mediaType {
        case .wav, .mp3, .m4a, .flac:
            return true
        case .aac, .aiff, .caf, .ogg, .opus, .mp4, .mov, .m4v:
            return false
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
