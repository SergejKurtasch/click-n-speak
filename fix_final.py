import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

target = "    func addManualTerm(_ term: String, language: String) -> Bool {\n        return true\n    }"
insertion = """
    var fakeFailures: [String: Error] = [:]

    func setPromptUpdateMode(_ mode: String) throws {
        if let error = fakeFailures["setPromptUpdateMode"] { throw error }
    }

    func pendingSuggestions() -> [String: [TermCandidate]] {
        return [:]
    }

    func runPromptAnalysis(onDemand: Bool) async throws {
        if let error = fakeFailures["runPromptAnalysis"] { throw error }
    }
"""

content = content.replace(target, target + "\n" + insertion)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
