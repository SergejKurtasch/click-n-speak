import Foundation

public struct TermCandidate: Codable, Sendable, Equatable {
    public let term: String
    public let count: Int
    public let correctionCount: Int
    public let frequencyCount: Int
    public let source: String

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
