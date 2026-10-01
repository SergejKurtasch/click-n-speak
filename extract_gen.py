import sys
import re

with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "r") as f:
    content = f.read()

# Instead of `generation: 1`, we can do `generation: extractGeneration(coordinator: coordinator)`
# Let's add a helper inside the file or just use `coordinator.state.recoveryGeneration`
# Actually, wait, `coordinator.state` doesn't expose `recoveryActions` easily without a `case let` match.
# But in all these tests we can just extract it right before!

def replace_with_extracted(content):
    new_content = ""
    lines = content.splitlines()
    for i, line in enumerate(lines):
        if "coordinator.keepPreviousRuntime(generation: 1)" in line:
            new_content += "        var gen = 1\n"
            new_content += "        if case let .degraded(_, _, _, recovery) = coordinator.state, let first = recovery.first { gen = first.generation }\n"
            new_content += line.replace("generation: 1", "generation: gen") + "\n"
        else:
            new_content += line + "\n"
    return new_content

content = replace_with_extracted(content)

with open("ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift", "w") as f:
    f.write(content)
