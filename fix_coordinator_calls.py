import sys

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    content = f.read()

# Fix `[.retry]` to `[RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation)]`
# Wait! In lines 326 and 612, `generation` is just `self.generation` (because they are outside `recoveryActions`)
content = content.replace("recovery: [.retry]", "recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation)]")
content = content.replace("recovery: [.retry, .keepPreviousRuntime]", "recovery: [RuntimeRecoveryCommand(kind: .retry, target: .general, generation: generation), RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general, generation: generation)]")

# Fix `backend.lowercased(, generation: generation)` syntax errors
content = content.replace("backend.lowercased(, generation: generation)", "backend.lowercased()")
content = content.replace("b.lowercased(, generation: generation)", "b.lowercased()")

# Fix extra argument 'generation' in `.cloudProvider` and `.localModel`
content = content.replace("target: .cloudProvider(name: provider, generation: generation)", "target: .cloudProvider(name: provider), generation: generation")
content = content.replace("target: .cloudProvider(name: backend, generation: generation)", "target: .cloudProvider(name: backend), generation: generation")
content = content.replace("target: .cloudProvider(name: backend.lowercased())), generation: generation", "target: .cloudProvider(name: backend.lowercased()), generation: generation")
content = content.replace("target: .cloudProvider(name: backend.lowercased()), generation: generation", "target: .cloudProvider(name: backend.lowercased()), generation: generation")
content = content.replace("target: .cloudProvider(name: b.lowercased()), generation: generation", "target: .cloudProvider(name: b.lowercased()), generation: generation")

content = content.replace("target: .localModel(id: id, generation: generation)", "target: .localModel(id: id), generation: generation")
content = content.replace("recoveryActions(for: error, generation: generation)", "recoveryActions(generation: generation, for: error)")

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.write(content)
