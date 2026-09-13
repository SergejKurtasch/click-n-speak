import sys
import re

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

# I will find "func addManualTerm" and replace it
match = re.search(r'    func addManualTerm\(.*?\)\s*->\s*Bool\s*\{.*?\n    \}', content, re.DOTALL)
if match:
    old = match.group(0)
    new = """    func addManualTermValidated(_ term: String, language: String) throws -> Bool {
        return true
    }

    func addManualTerm(_ term: String, language: String) -> Bool {
        return true
    }"""
    content = content.replace(old, new)
else:
    print("Not found!")

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
