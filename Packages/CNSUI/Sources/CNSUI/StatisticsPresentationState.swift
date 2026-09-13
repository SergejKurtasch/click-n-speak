import Foundation
import CNSDictionary
import CNSCore


public enum StatisticsPresentationState: Equatable, Sendable {
    case idle
    case loading(UUID)
    case ready(UUID, JSONObject)
    case failed(UUID)
    
    public static func == (lhs: StatisticsPresentationState, rhs: StatisticsPresentationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case let (.loading(id1), .loading(id2)): return id1 == id2
        case let (.ready(id1, _), .ready(id2, _)): return id1 == id2
        case let (.failed(id1), .failed(id2)): return id1 == id2
        default: return false
        }
    }
}
