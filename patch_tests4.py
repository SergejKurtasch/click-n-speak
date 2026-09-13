import sys

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "r") as f:
    content = f.read()

old_assertion2 = """        try coordinator.revert(language: "en")
        XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), [])"""

new_assertion2 = """        try coordinator.revert(language: "en")
        XCTAssertEqual(coordinator.terms().filter { $0.language == "en" }.map { $0.term }, [])"""

content = content.replace(old_assertion2, new_assertion2)

with open("Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift", "w") as f:
    f.write(content)
