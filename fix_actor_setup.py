import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

content = content.replace("override func setUp() {", "override func setUp() async throws {\n        try await super.setUp()")
content = content.replace("super.setUp()", "")
content = content.replace("sut = MenuBarController(", "sut = await MenuBarController(")

# the repoResources is private func repoResources() -> AppResources {
content = content.replace("private func repoResources() -> AppResources {", "@MainActor private func repoResources() -> AppResources {")
content = content.replace("let resources = repoResources()", "let resources = await repoResources()")

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
    f.write(content)
