import sys

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    lines = f.readlines()

new_lines = []
skip = False
for line in lines:
    if line.startswith("enum RuntimeRecoveryCommand: String, Sendable, Equatable {"):
        skip = True
    
    if not skip:
        new_lines.append(line)
        
    if skip and line.strip() == "}":
        # Check if the preceding lines were the enum cases
        # We can just skip until the first `}`
        skip = False

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.writelines(new_lines)
