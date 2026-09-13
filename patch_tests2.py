import sys

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "r") as f:
    content = f.read()

old_test = """
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

new_test = """
    func testRevertRestoresPreviousStateAndPreservesUseCount() throws {
        let paths = makePaths()
        var config = makeConfig()
        let initialTerms: [JSONValue] = [
            .object(JSONObject([
                ("term", .string("SwiftUI")),
                ("source", .string("manual")),
                ("use_count", .int(5))
            ])),
            .object(JSONObject([
                ("term", .string("Combine")),
                ("source", .string("manual")),
                ("use_count", .int(2))
            ]))
        ]
        var userTerms = config.raw["user_terms"]?.objectValue ?? JSONObject()
        userTerms["en"] = .array(initialTerms)
        config.raw["user_terms"] = .object(userTerms)
        
        let coordinator = makeCoordinator(config: config, paths: paths)
        
        try coordinator.deleteTerm(language: "en", term: "Combine")
        
        var currentTerms = coordinator.snapshot.raw["user_terms"]?.objectValue?["en"]?.arrayValue ?? []
        for i in 0..<currentTerms.count {
            var obj = currentTerms[i].objectValue!
            if obj["term"]?.stringValue == "SwiftUI" {
                obj["use_count"] = .int(10)
                currentTerms[i] = .object(obj)
            }
        }
        var newByLang = coordinator.snapshot.raw["user_terms"]?.objectValue ?? JSONObject()
        newByLang["en"] = .array(currentTerms)
        var newConfig = coordinator.snapshot
        newConfig.raw["user_terms"] = .object(newByLang)
        coordinator.adoptConfiguration(newConfig)
        
        XCTAssertTrue(coordinator.canRevert(language: "en"))
        try coordinator.revert(language: "en")
        
        let finalTerms = UserTerms.activeTerms(coordinator.snapshot, lang: "en")
        XCTAssertEqual(finalTerms.count, 2)
        let finalSwiftUI = finalTerms.first(where: { $0.term == "SwiftUI" })
        XCTAssertEqual(finalSwiftUI?.useCount, 10)
        let finalCombine = finalTerms.first(where: { $0.term == "Combine" })
        XCTAssertEqual(finalCombine?.useCount, 2)
    }
"""

content = content.replace(old_test, new_test)

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "w") as f:
    f.write(content)
