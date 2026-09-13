import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    doubles = f.read()

new_funcs = """    var shouldFailWrite = false
    var shouldFailAnalysis = false

    func setPromptUpdateMode(_ mode: String) throws {
        if shouldFailWrite { throw DictionaryCoordinatorError.noSnapshot }
    }
    func pendingSuggestions() -> [String: [CNSDictionary.TermCandidate]] { return [:] }
    func runPromptAnalysis(onDemand: Bool) async throws {
        if shouldFailAnalysis { throw DictionaryCoordinatorError.suggestionNotFound }
    }
}"""

doubles = doubles.replace("""    func setPromptUpdateMode(_ mode: String) throws { }
    func pendingSuggestions() -> [String: [CNSDictionary.TermCandidate]] { return [:] }
    func runPromptAnalysis(onDemand: Bool) async throws { }
}""", new_funcs)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(doubles)
