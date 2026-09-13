import sys

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "r") as f:
    content = f.read()

test = """
    func testAddingFirstTermCanRevertToEmptyDictionary() throws {
        let paths = makePaths()
        let coordinator = makeCoordinator(config: makeConfig(), paths: paths)
        XCTAssertTrue(coordinator.addManualTerm("SwiftUI", language: "en"))
        try coordinator.revert(language: "en")
        XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), [])
    }
    
    func testRevertRestoresPreviousStateAndPreservesUseCount() throws {
        let paths = makePaths()
        var config = makeConfig()
        let initialTerms = [
            makeTermItem("SwiftUI", source: "manual", useCount: 5),
            makeTermItem("Combine", source: "manual", useCount: 2)
        ]
        var userTerms = config.raw["user_terms"]?.objectValue ?? JSONObject()
        userTerms["en"] = .array(initialTerms)
        config.raw["user_terms"] = .object(userTerms)
        
        let coordinator = makeCoordinator(config: config, paths: paths)
        
        // Delete a term -> creates snapshot of [SwiftUI, Combine]
        try coordinator.deleteTerm(language: "en", term: "Combine")
        
        // Emulate some usage on the remaining term
        var currentTerms = coordinator.snapshot.raw["user_terms"]?.objectValue?["en"]?.arrayValue ?? []
        for i in 0..<currentTerms.count {
            var obj = currentTerms[i].objectValue!
            if obj["term"]?.stringValue == "SwiftUI" {
                obj["use_count"] = .int(10) // Updated usage
                currentTerms[i] = .object(obj)
            }
        }
        var newByLang = coordinator.snapshot.raw["user_terms"]?.objectValue ?? JSONObject()
        newByLang["en"] = .array(currentTerms)
        var newConfig = coordinator.snapshot
        newConfig.raw["user_terms"] = .object(newByLang)
        coordinator.adoptConfiguration(newConfig)
        
        // Revert -> should restore [SwiftUI, Combine], but SwiftUI should keep use_count = 10
        XCTAssertTrue(coordinator.canRevert(language: "en"))
        try coordinator.revert(language: "en")
        
        let finalTerms = UserTerms.activeTerms(coordinator.snapshot, lang: "en")
        XCTAssertEqual(finalTerms.count, 2)
        let finalSwiftUI = finalTerms.first { $0.term == "SwiftUI" }
        XCTAssertEqual(finalSwiftUI?.useCount, 10) // Preserved
        let finalCombine = finalTerms.first { $0.term == "Combine" }
        XCTAssertEqual(finalCombine?.useCount, 2) // Restored
    }
"""

content = content.replace("final class DictionaryCoordinatorTests: XCTestCase {", "final class DictionaryCoordinatorTests: XCTestCase {" + test)

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "w") as f:
    f.write(content)
