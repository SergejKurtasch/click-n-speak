import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

content = content.replace("final class CredentialDialogTests: XCTestCase {", "@MainActor\nfinal class CredentialDialogTests: XCTestCase {")

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
    f.write(content)

