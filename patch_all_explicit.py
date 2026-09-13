import sys

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    lines = f.read().splitlines()

# 511: deleteTerm
# 541: editTerm
# 558: reactivateTerm
# 621: importPromptText
# 647: revert -> SHOULD REMAIN commit
# 719: resolveSuggestions
# 730: addAllPendingSuggestions
# 1180: runPromptAnalysis

indices_to_change = [510, 540, 557, 620, 718, 729, 1179]

for i in indices_to_change:
    lines[i] = lines[i].replace("try commit(", "try commitTermMutation(").replace("promptLanguages:", "languages:")

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write("\n".join(lines))
