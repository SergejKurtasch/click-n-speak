import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

old = """    func addManualTerm(_ term: String, language: String) -> Bool {
        // No-op for tests
        return true
    }"""
new = """    func addManualTermValidated(_ term: String, language: String) throws -> Bool {
        return true
    }
    
    func addManualTerm(_ term: String, language: String) -> Bool {
        return true
    }"""
content = content.replace(old, new)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
