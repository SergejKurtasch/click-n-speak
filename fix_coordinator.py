import sys

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    content = f.read()

content = content.replace("private func recoveryActions(generation: generation,", "private func recoveryActions(generation: Int,")
content = content.replace("private func recoveryActions(generation: generation, for error: Error)", "private func recoveryActions(generation: Int, for error: Error)")

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.write(content)
