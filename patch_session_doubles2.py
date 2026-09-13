import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

stubs = """
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

# replace the empty stubs
old_stubs = """
    func setPromptUpdateMode(_ mode: String) throws { }
    func pendingSuggestions() -> [String: [TermCandidate]] { return [:] }
    func runPromptAnalysis(onDemand: Bool) async throws { }
"""

content = content.replace(old_stubs, stubs)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
