import re

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    content = f.read()

# Pass generation to recoveryActions
content = content.replace("recoveryActions(", "recoveryActions(generation: generation, ")
# Fix the two places where I used recoveryActions inside recoveryActions
content = content.replace("recoveryActions(generation: generation, for: error)", "recoveryActions(for: error, generation: generation)")

old_recovery1 = """    private func recoveryActions(
        for error: Error,
        deactivatedCredential: Bool
    ) -> [RuntimeRecoveryCommand] {"""
new_recovery1 = """    private func recoveryActions(
        generation: Int,
        for error: Error,
        deactivatedCredential: Bool
    ) -> [RuntimeRecoveryCommand] {"""
content = content.replace(old_recovery1, new_recovery1)

# Add generation to all commands in recoveryActions1
content = re.sub(
    r'RuntimeRecoveryCommand\(kind: \.([^,]+), target: \.([^)]+)\)',
    r'RuntimeRecoveryCommand(kind: .\1, target: .\2, generation: generation)',
    content
)

old_recovery2 = """    private func recoveryActions(for error: Error) -> [RuntimeRecoveryCommand] {"""
new_recovery2 = """    private func recoveryActions(for error: Error, generation: Int) -> [RuntimeRecoveryCommand] {"""
content = content.replace(old_recovery2, new_recovery2)


old_keep = """    func keepPreviousRuntime() {
        guard !shutdownRequested else { return }"""
new_keep = """    func keepPreviousRuntime(generation: Int) {
        guard !shutdownRequested else { return }
        guard generation == desiredGeneration else { return }"""
content = content.replace(old_keep, new_keep)

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.write(content)
