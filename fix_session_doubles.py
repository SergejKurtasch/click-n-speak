import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    lines = f.readlines()

# First, remove the wrongly added methods at the end of the file.
# They look like:
#    var fakeFailures: [String: Error] = [:]
#    func setPromptUpdateMode(_ mode: String) throws { ...
#    func pendingSuggestions() -> [String: [TermCandidate]] { ...
#    func runPromptAnalysis(onDemand: Bool) async throws { ...
# }

new_lines = []
skip = False
for line in lines:
    if "var fakeFailures: [String: Error] = [:]" in line:
        skip = True
    if skip and line.strip() == "}":
        skip = False
        new_lines.append(line)
        continue
    if not skip:
        new_lines.append(line)

content = "".join(new_lines)

# Now, find `final class FakeDictionaryCoordinator` and insert the methods before its closing brace.
# Let's find the class, then find the matching closing brace, or just put it after `func revert(language: String?) throws { }`

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

if "func setPromptUpdateMode" not in content:
    # Let's find the closing brace of FakeDictionaryCoordinator
    # Just look for `func revert(language: String?) throws { }`
    target = "func revert(language: String?) throws { }"
    content = content.replace(target, target + "\n" + insertion)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)

