import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

repo_method = """    private func repoResources() -> AppResources {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return AppResources(
            localesDirectory: repoRoot.appendingPathComponent("locales"),
            iconsDirectory: repoRoot.appendingPathComponent("ClickNSpeak/Resources")
        )
    }
"""

content = content.replace("final class CredentialDialogTests: XCTestCase {", "final class CredentialDialogTests: XCTestCase {\n" + repo_method)

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
    f.write(content)
