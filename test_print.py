import sys

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "r") as f:
    content = f.read()

import re

match = re.search(r'let i18n = I18n.load\("en", localesDirectory: resources.localesDirectory\)', content)
if match:
    old_code = match.group(0)
    new_code = """print("LOCALES DIRECTORY: \\(resources.localesDirectory.path)")
        let i18n = I18n.load("en", localesDirectory: resources.localesDirectory)"""
    content = content.replace(old_code, new_code)
    
    # Also fix the previous syntax error (remove the print sut.i18n.t)
    content = re.sub(r'print\("I18N LOADED VALUE: .*?"\)\n\s*', '', content)
    
    with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
        f.write(content)
else:
    print("Not found regex!")
