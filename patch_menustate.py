with open("Packages/CNSUI/Sources/CNSUI/MenuState.swift", "r") as f:
    content = f.read()

# Delete MenuRuntimeRecoveryAction
import re
content = re.sub(r'public enum MenuRuntimeRecoveryAction: String, Sendable, Equatable \{[^}]+\}', '', content)

# Replace MenuRuntimeRecoveryAction with RuntimeRecoveryCommand
content = content.replace("MenuRuntimeRecoveryAction", "RuntimeRecoveryCommand")

with open("Packages/CNSUI/Sources/CNSUI/MenuState.swift", "w") as f:
    f.write(content)
