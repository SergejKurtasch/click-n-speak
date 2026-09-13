import sys

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    content = f.read()

content = content.replace(
    "recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation)]",
    "recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: self.generation)]"
)
content = content.replace(
    "recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation), RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: generation)]",
    "recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: self.generation), RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: self.generation)]"
)

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.write(content)
