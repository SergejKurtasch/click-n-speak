import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

new_funcs = """    func canRevert(language: String?) -> Bool {
        return false
    }

    func revert(language: String?) throws {
        // No-op
    }
"""

content = content.replace("    func addManualTermValidated", new_funcs + "\n    func addManualTermValidated")

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
