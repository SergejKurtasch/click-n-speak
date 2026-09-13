import sys

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    content = f.read()

content = content.replace(
    "generation: self.generation",
    "generation: desiredGeneration"
)

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.write(content)
