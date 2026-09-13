import sys

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    content = f.read()

old = "try commit(candidate, promptLanguages: [LanguageCode.normalize(language)], invalidations: [.terms])"
new = "try commitTermMutation(candidate, languages: [LanguageCode.normalize(language)], invalidations: [.terms])"
content = content.replace(old, new)

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write(content)
