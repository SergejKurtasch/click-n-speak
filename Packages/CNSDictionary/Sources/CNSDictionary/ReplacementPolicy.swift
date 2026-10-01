import CNSCore
import Foundation

public enum ReplacementRowState: String, Sendable, Equatable {
    case active
    case candidate
    case readyForReview
    case rejected
}

public struct ReplacementRow: Sendable, Equatable, Identifiable {
    public var id: String {
        "\(state.rawValue)||\(source)||\(bucket ?? "manual")||\(ReplacementPolicy.key(from: from, to: to))"
    }

    public let source: String
    public let bucket: String?
    public let from: String
    public let to: String
    public let count: Int
    public let lastSeen: String?
    public let addedAt: String?
    public let state: ReplacementRowState

    public init(
        source: String,
        bucket: String?,
        from: String,
        to: String,
        count: Int,
        lastSeen: String?,
        addedAt: String?,
        state: ReplacementRowState
    ) {
        self.source = source
        self.bucket = bucket
        self.from = from
        self.to = to
        self.count = count
        self.lastSeen = lastSeen
        self.addedAt = addedAt
        self.state = state
    }
}

public struct ReplacementSections: Sendable, Equatable {
    public let active: [ReplacementRow]
    public let candidates: [ReplacementRow]
    public let rejected: [ReplacementRow]

    public init(
        active: [ReplacementRow] = [],
        candidates: [ReplacementRow] = [],
        rejected: [ReplacementRow] = []
    ) {
        self.active = active
        self.candidates = candidates
        self.rejected = rejected
    }
}

struct ReplacementDecision: Sendable, Equatable {
    let from: String
    let to: String
    let timestamp: String?
}

enum ReplacementPolicy {
    static let approvedKey = "approved_auto_replacements"
    static let rejectedKey = "rejected_replacements"

    static func key(from: String, to: String) -> String {
        "\(TermCanonicalizer.canonicalKey(from))||\(TermCanonicalizer.canonicalKey(to))"
    }

    static func sourceKey(_ from: String) -> String {
        TermCanonicalizer.canonicalKey(from)
    }

    static func decisions(
        in config: Config,
        key configKey: String,
        timestampKey: String
    ) -> [ReplacementDecision] {
        decisions(in: config.raw, key: configKey, timestampKey: timestampKey)
    }

    static func decisions(
        in config: JSONObject,
        key configKey: String,
        timestampKey: String
    ) -> [ReplacementDecision] {
        var seen = Set<String>()
        var result: [ReplacementDecision] = []
        for value in config[configKey]?.arrayValue ?? [] {
            guard let object = value.objectValue else { continue }
            let from = VocabProvider.normalizeReplacementSide(object["from"]?.stringValue ?? "")
            let to = VocabProvider.normalizeReplacementSide(object["to"]?.stringValue ?? "")
            guard !from.isEmpty, !to.isEmpty else { continue }
            let identity = key(from: from, to: to)
            guard seen.insert(identity).inserted else { continue }
            result.append(ReplacementDecision(
                from: from,
                to: to,
                timestamp: object[timestampKey]?.stringValue
            ))
        }
        return result
    }

    static func encode(_ decisions: [ReplacementDecision], timestampKey: String) -> JSONValue {
        var seen = Set<String>()
        let values = decisions.compactMap { decision -> JSONValue? in
            let from = VocabProvider.normalizeReplacementSide(decision.from)
            let to = VocabProvider.normalizeReplacementSide(decision.to)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            guard seen.insert(key(from: from, to: to)).inserted else { return nil }
            var object = JSONObject()
            object["from"] = .string(from)
            object["to"] = .string(to)
            if let timestamp = decision.timestamp { object[timestampKey] = .string(timestamp) }
            return .object(object)
        }
        return .array(values)
    }

    static func bucket(for text: String) -> String? {
        let hasCyrillic = text.range(of: #"[\u{0400}-\u{052F}]"#, options: .regularExpression) != nil
        let hasLatin = text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
        if hasCyrillic, !hasLatin { return "cyrillic" }
        if hasLatin, !hasCyrillic { return "latin" }
        return nil
    }
}
