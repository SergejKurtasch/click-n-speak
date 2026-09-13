with open("Packages/CNSCore/Sources/CNSCore/RuntimeRecoveryCommand.swift", "r") as f:
    content = f.read()

content = content.replace("public let target: RuntimeRecoveryTarget", "public let target: RuntimeRecoveryTarget\n    public let generation: Int")
content = content.replace("init(kind: RuntimeRecoveryKind, target: RuntimeRecoveryTarget)", "init(kind: RuntimeRecoveryKind, target: RuntimeRecoveryTarget, generation: Int = 0)")
content = content.replace("self.target = target", "self.target = target\n        self.generation = generation")

with open("Packages/CNSCore/Sources/CNSCore/RuntimeRecoveryCommand.swift", "w") as f:
    f.write(content)
