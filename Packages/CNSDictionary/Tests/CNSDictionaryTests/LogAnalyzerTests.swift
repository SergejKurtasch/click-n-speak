import XCTest
import CNSCore
@testable import CNSDictionary

final class LogAnalyzerTests: XCTestCase {
    func testFrequencyCountEmpty() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = PhraseHistory(fileURL: tempURL)

        let counts = LogAnalyzer.getFrequentTerms(phraseHistory: history)
        XCTAssertTrue(counts.enTerms.isEmpty)
        XCTAssertTrue(counts.ruBigrams.isEmpty)
    }
}
