import sys

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    content = f.read()

commit_mutation = """    private func commitTermMutation(
        _ candidate: Config,
        languages: Set<String>,
        invalidations: DictionaryInvalidations
    ) throws {
        var mutableCandidate = candidate
        TermUndoPolicy.capturePreviousTerms(
            from: snapshot,
            into: &mutableCandidate,
            languages: languages
        )
        try commit(mutableCandidate, promptLanguages: languages, invalidations: invalidations)
    }

    private func commit("""

content = content.replace("    private func commit(", commit_mutation)

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write(content)
