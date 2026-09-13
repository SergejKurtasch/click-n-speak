import sys

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "r") as f:
    content = f.read()

old_assertion = """        let finalTerms = UserTerms.activeTerms(coordinator.snapshot, lang: "en")
        XCTAssertEqual(finalTerms.count, 2)
        let finalSwiftUI = finalTerms.first(where: { $0.term == "SwiftUI" })
        XCTAssertEqual(finalSwiftUI?.useCount, 10)
        let finalCombine = finalTerms.first(where: { $0.term == "Combine" })
        XCTAssertEqual(finalCombine?.useCount, 2)"""

new_assertion = """        let finalTerms = coordinator.terms().filter { $0.language == "en" }
        XCTAssertEqual(finalTerms.count, 2)
        let finalSwiftUI = finalTerms.first(where: { $0.term == "SwiftUI" })
        XCTAssertEqual(finalSwiftUI?.useCount, 10)
        let finalCombine = finalTerms.first(where: { $0.term == "Combine" })
        XCTAssertEqual(finalCombine?.useCount, 2)"""

content = content.replace(old_assertion, new_assertion)

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "w") as f:
    f.write(content)
