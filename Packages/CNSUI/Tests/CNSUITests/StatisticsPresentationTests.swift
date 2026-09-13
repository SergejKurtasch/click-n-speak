import Testing
import Foundation
import CNSCore
@testable import CNSUI

@Suite
struct StatisticsPresentationTests {
    @Test func stateEquality() {
        let id1 = UUID()
        let id2 = UUID()
        let dict1 = JSONObject([])
        let dict2 = JSONObject([("b", .int(2))])
        
        #expect(StatisticsPresentationState.idle == StatisticsPresentationState.idle)
        #expect(StatisticsPresentationState.loading(id1) == StatisticsPresentationState.loading(id1))
        #expect(StatisticsPresentationState.loading(id1) != StatisticsPresentationState.loading(id2))
        
        #expect(StatisticsPresentationState.ready(id1, dict1) == StatisticsPresentationState.ready(id1, dict2))
        #expect(StatisticsPresentationState.ready(id1, dict1) != StatisticsPresentationState.ready(id2, dict1))
        
        #expect(StatisticsPresentationState.failed(id1) == StatisticsPresentationState.failed(id1))
        #expect(StatisticsPresentationState.failed(id1) != StatisticsPresentationState.failed(id2))
        
        #expect(StatisticsPresentationState.idle != StatisticsPresentationState.loading(id1))
    }
}

