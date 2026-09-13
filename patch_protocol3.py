import sys

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    content = f.read()

content = content.replace("func pendingSuggestions() -> [String: [DictionaryTerm]]", "func pendingSuggestions() -> [String: [TermCandidate]]")

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write(content)

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    doubles = f.read()

doubles = doubles.replace("func pendingSuggestions() -> [String: [CNSDictionary.DictionaryTerm]]", "func pendingSuggestions() -> [String: [CNSDictionary.TermCandidate]]")

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(doubles)

