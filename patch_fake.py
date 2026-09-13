import sys

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "r") as f:
    content = f.read()

new_funcs = """    func setPromptUpdateMode(_ mode: String) throws { }
    func pendingSuggestions() -> [String: [CNSDictionary.DictionaryTerm]] { return [:] }
    func runPromptAnalysis(onDemand: Bool) async throws { }
}"""

content = content.replace("}\n\nfinal class FakeInputMethod:", new_funcs + "\n\nfinal class FakeInputMethod:")

with open("Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift", "w") as f:
    f.write(content)
