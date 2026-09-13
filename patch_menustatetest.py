with open("Packages/CNSUI/Tests/CNSUITests/MenuStateTests.swift", "r") as f:
    content = f.read()

content = content.replace(
    "state.runtime.recoveryActions = [.openAPIKeys, .keepPreviousRuntime, .retry]",
    "state.runtime.recoveryActions = [RuntimeRecoveryCommand(kind: .openAPIKeys, target: .general), RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general), RuntimeRecoveryCommand(kind: .retry, target: .general)]"
)

with open("Packages/CNSUI/Tests/CNSUITests/MenuStateTests.swift", "w") as f:
    f.write(content)
