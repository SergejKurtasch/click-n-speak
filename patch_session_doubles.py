import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

# I will add the missing stubs at the end of the class.
stubs = """
    func setPromptUpdateMode(_ mode: String) throws { }
    func pendingSuggestions() -> [String: [TermCandidate]] { return [:] }
    func runPromptAnalysis(onDemand: Bool) async throws { }
"""

content = content.replace("    var fakeFailures: [String: Error] = [:]\n}", "    var fakeFailures: [String: Error] = [:]\n" + stubs + "}")

# If fakeFailures is not there, I will insert before the last brace.
if "fakeFailures" not in content:
    idx = content.rfind("}")
    content = content[:idx] + stubs + "\n" + content[idx:]

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
