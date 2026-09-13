import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

import re
match = re.search(r'    private func repoResources\(\) -> AppResources \{.*?\n    \}', content, re.DOTALL)

if match:
    old_code = match.group(0)
    new_code = """    private func repoResources() -> AppResources {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales").path) {
                return AppResources(
                    localesDirectory: directory.appendingPathComponent("locales"),
                    iconsDirectory: directory.appendingPathComponent("ClickNSpeak/Resources")
                )
            }
            directory.deleteLastPathComponent()
        }
        fatalError("Repository root not found")
    }"""
    content = content.replace(old_code, new_code)
    
    # Also remove the print I added
    content = re.sub(r'print\("LOCALES DIRECTORY: .*?"\)\n\s*', '', content)
    
    with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
        f.write(content)
else:
    print("Not found regex!")
