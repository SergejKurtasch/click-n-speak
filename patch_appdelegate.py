with open("ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift", "r") as f:
    content = f.read()

content = content.replace("runtimeCoordinator?.keepPreviousRuntime()", "runtimeCoordinator?.keepPreviousRuntime(generation: action.generation)")

with open("ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift", "w") as f:
    f.write(content)
