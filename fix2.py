import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

# I will find the EXACT end of FakeDictionaryCoordinator.
# Let's search for `    func addManualTerm(_ term: String, language: String) -> Bool {\n        return true\n    }`
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

if target in content:
    content = content.replace(target, target + "\n" + insertion)
else:
    print("Could not find target block!")

# Remove any extraneous `}` at the end of the file
content = content.rstrip()
while content.endswith("}"):
    # check if it's an extraneous one. 
    # Actually wait! The file should end with } because FakeAiEditor is a class.
    # But earlier I might have left an extra `}`.
    pass

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
