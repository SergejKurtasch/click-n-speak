with open("Packages/CNSCore/Sources/CNSCore/RuntimeRecoveryCommand.swift", "r") as f:
    content = f.read()

if "case retry" not in content:
    content = content.replace("case keepPreviousRuntime", "case keepPreviousRuntime\n    case retry")

with open("Packages/CNSCore/Sources/CNSCore/RuntimeRecoveryCommand.swift", "w") as f:
    f.write(content)
