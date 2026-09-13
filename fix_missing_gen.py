import sys
import re

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    content = f.read()

content = content.replace(
    "return [RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: backend.lowercased()))]",
    "return [RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: backend.lowercased()), generation: generation)]"
)
content = content.replace(
    "cmds.append(RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: b.lowercased())))",
    "cmds.append(RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: b.lowercased()), generation: generation))"
)

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.write(content)
