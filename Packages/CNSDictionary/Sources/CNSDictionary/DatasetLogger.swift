import CNSCore
import Foundation

/// Provenance for one recording segment contributing to a popup draft.
public struct DatasetSegment: Sendable {
    public var rawWhisper: String
    public var aiEdited: String?
    public var aiStatus: String?
    public var runtime: RuntimeDescriptor
    public var promptHash: String

    public init(
        rawWhisper: String,
        aiEdited: String? = nil,
        aiStatus: String? = nil,
        runtime: RuntimeDescriptor,
        promptHash: String
    ) {
        self.rawWhisper = rawWhisper
        self.aiEdited = aiEdited
        self.aiStatus = aiStatus
        self.runtime = runtime
        self.promptHash = promptHash
    }
}

/// One dictation, as stored in the fine-tuning dataset.
public struct DatasetRecord: Sendable {
    public var rawWhisper: String
    public var aiEdited: String?
    public var aiStatus: String?
    public var sttBackend: String?
    public var sttModel: String?
    public var aiModel: String?
    public var userFinal: String
    public var lang: String?
    public var promptHash: String?
    /// Active dictionary terms for `lang`, used to compute term hit rates.
    public var userTerms: [String]
    /// Present only for drafts assembled from multiple recording segments.
    public var segments: [DatasetSegment]?

    public init(
        rawWhisper: String,
        aiEdited: String? = nil,
        aiStatus: String? = nil,
        sttBackend: String? = nil,
        sttModel: String? = nil,
        aiModel: String? = nil,
        userFinal: String,
        lang: String? = nil,
        promptHash: String? = nil,
        userTerms: [String] = [],
        segments: [DatasetSegment]? = nil
    ) {
        self.rawWhisper = rawWhisper
        self.aiEdited = aiEdited
        self.aiStatus = aiStatus
        self.sttBackend = sttBackend
        self.sttModel = sttModel
        self.aiModel = aiModel
        self.userFinal = userFinal
        self.lang = lang
        self.promptHash = promptHash
        self.userTerms = userTerms
        self.segments = segments
    }
}

/// Append-only JSONL dataset of (raw, ai-edited, user-final) triplets.
///
/// Ported from `dataset_logger.py`. Field order and the compact
/// `ensure_ascii=False` encoding match Python exactly — `scripts/print_metrics.py`
/// and `term_effectiveness.py` read this same file.
public struct DatasetLogger: Sendable {
    private let fileURL: URL
    private let log: @Sendable (String) -> Void

    public init(fileURL: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.log = log
    }

    @discardableResult
    public func append(_ record: DatasetRecord, at date: Date = Date()) -> Bool {
        let line = Self.jsonLine(record, at: date) + "\n"
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            return true
        } catch {
            log("Failed to write dataset record: \(error)")
            return false
        }
    }

    static func jsonLine(_ record: DatasetRecord, at date: Date) -> String {
        var object = JSONObject()
        object["timestamp"] = .string(isoUTC(date))
        object["raw_whisper"] = .string(record.rawWhisper)
        object["ai_edited"] = record.aiEdited.map { JSONValue.string($0) } ?? .null
        object["ai_status"] = record.aiStatus.map { JSONValue.string($0) } ?? .null
        object["stt_backend"] = record.sttBackend.map { JSONValue.string($0) } ?? .null
        object["stt_model"] = record.sttModel.map { JSONValue.string($0) } ?? .null
        object["ai_model"] = record.aiModel.map { JSONValue.string($0) } ?? .null
        object["user_final"] = .string(record.userFinal)
        object["lang"] = record.lang.map { JSONValue.string($0) } ?? .null
        object["prompt_hash"] = record.promptHash.map { JSONValue.string($0) } ?? .null
        object["vocab_terms_in_raw"] = .array(
            findTerms(in: record.rawWhisper, terms: record.userTerms).map { .string($0) }
        )
        object["vocab_terms_in_final"] = .array(
            findTerms(in: record.userFinal, terms: record.userTerms).map { .string($0) }
        )
        if let segments = record.segments {
            object["segments"] = .array(segments.map { segment in
                var value = JSONObject()
                value["raw_whisper"] = .string(segment.rawWhisper)
                value["ai_edited"] = segment.aiEdited.map(JSONValue.string) ?? .null
                value["ai_status"] = segment.aiStatus.map(JSONValue.string) ?? .null
                value["stt_backend"] = .string(segment.runtime.transcriber.backend)
                value["stt_model"] = .string(segment.runtime.transcriber.modelID)
                value["ai_backend"] = .string(segment.runtime.aiEditor.backend)
                value["ai_model"] = segment.runtime.aiEditor.modelID.map(JSONValue.string) ?? .null
                value["prompt_hash"] = .string(segment.promptHash)
                return .object(value)
            })
        }
        return JSONValue.object(object).serializedJSONLine()
    }

    /// Canonical keys of dictionary terms present in `text`. Single words match
    /// on token identity; phrases match as substrings, so "machine learning"
    /// counts even though neither token alone is a term.
    static func findTerms(in text: String, terms: [String]) -> [String] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        let tokens = Set(tokenize(text).map(TermCanonicalizer.canonicalKey))
        let lowered = text.lowercased()
        var found = Set<String>()
        for term in terms {
            let key = TermCanonicalizer.canonicalKey(term)
            guard !key.isEmpty else { continue }
            if key.contains(" ") {
                if lowered.contains(key) { found.insert(key) }
            } else if tokens.contains(key) {
                found.insert(key)
            }
        }
        return found.sorted()
    }

    /// Equivalent of the Python `[\w\-.+#]+` word regex.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber || char == "_" || "-.+#".contains(char) {
                current.append(char)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func isoUTC(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        let micros = Int((Double(c.nanosecond ?? 0) / 1000).rounded())
        // Python's datetime.isoformat() drops the fractional part when it is zero.
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        let fraction = micros == 0 ? "" : String(format: ".%06d", micros)
        return base + fraction + "+00:00"
    }
}
