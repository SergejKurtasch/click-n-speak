import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

target = "    func addManualTerm(_ term: String, language: String) -> Bool {\n        return true\n    }"
insertion = """
    func canRevert(language: String?) -> Bool {
        return false
    }

    func revert(language: String?) throws {
        // No-op
    }
"""

content = content.replace(target, target + "\n" + insertion)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
