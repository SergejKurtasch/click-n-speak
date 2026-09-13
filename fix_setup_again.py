import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

content = content.replace("try super.setUp()", "try await super.setUp()")

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
    f.write(content)

