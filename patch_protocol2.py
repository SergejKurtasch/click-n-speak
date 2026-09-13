import sys

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    content = f.read()

old_protocol = """    func addManualTerm(_ term: String, language: String) -> Bool
    func addManualTermValidated(_ term: String, language: String) throws -> Bool
    func canRevert(language: String?) -> Bool
    func revert(language: String?) throws
}"""

new_protocol = """    func addManualTerm(_ term: String, language: String) -> Bool
    func addManualTermValidated(_ term: String, language: String) throws -> Bool
    func canRevert(language: String?) -> Bool
    func revert(language: String?) throws
    func setPromptUpdateMode(_ mode: String) throws
    func pendingSuggestions() -> [String: [DictionaryTerm]]
    func runPromptAnalysis(onDemand: Bool) async throws
}"""

content = content.replace(old_protocol, new_protocol)

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write(content)
