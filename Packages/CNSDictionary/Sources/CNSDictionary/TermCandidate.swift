import Foundation

public struct TermCandidate: Codable, Sendable, Equatable {
    public let term: String
    public let count: Int
    public let correctionCount: Int
    public let frequencyCount: Int
    public let source: String

    /// Number of real observations shown to the user. Older persisted
    /// candidates may only have `count`, so keep that as a compatibility
    /// fallback until the next analysis refreshes them.
    public var evidenceCount: Int {
        let evidence = correctionCount + frequencyCount
        return evidence > 0 ? evidence : count
    }

    /// Internal ordering score. Corrections intentionally rank ahead of plain
    /// phrase frequency, but this value must never be presented as a total.
    public var rankingScore: Int {
        let evidence = correctionCount + frequencyCount
        return evidence > 0 ? correctionCount * 10 + frequencyCount : count
    }

    public init(
        term: String,
        count: Int,
        correctionCount: Int,
        frequencyCount: Int,
        source: String
    ) {
        self.term = term
        self.count = count
        self.correctionCount = correctionCount
        self.frequencyCount = frequencyCount
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case term, count, source
        case correctionCount = "correction_count"
        case frequencyCount = "frequency_count"
    }
}
