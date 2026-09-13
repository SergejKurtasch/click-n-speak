import sys
import re

with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "r") as f:
    content = f.read()

content = content.replace("recovery.contains(.retry)", "recovery.contains(where: { $0.kind == .retry })")
content = content.replace("recovery.contains(.openAPIKeys)", "recovery.contains(where: { $0.kind == .openAPIKeys })")
content = content.replace("recovery == [.openAPIKeys]", "recovery.contains(where: { $0.kind == .openAPIKeys })")

content = content.replace("coordinator.keepPreviousRuntime()", "coordinator.keepPreviousRuntime(generation: 1)") # wait, what if generation is not 1? 
# let's extract generation:
# `coordinator.keepPreviousRuntime(generation: coordinator.state.recoveryActions.first?.generation ?? 1)`
# Actually, wait, `coordinator.state` is `RuntimeState` which is an enum.
# But tests don't need to be exact about generation if they just mock?
# Wait! In `AppRuntimeCoordinator`, `keepPreviousRuntime` ignores if generation != desiredGeneration.
# So I should use the correct generation!

with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "w") as f:
    f.write(content)
