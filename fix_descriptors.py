import sys

with open("ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift", "r") as f:
    content = f.read()

content = content.replace(
    "registry.updateReason(t, reason: .activeRuntime(descriptor: TranscriberDescriptor(backend: \"local\", modelID: model.id, kind: .local)))",
    "registry.updateReason(t, reason: .activeRuntime(descriptor: RuntimeDescriptor(transcriber: TranscriberDescriptor(backend: \"local\", modelID: model.id, kind: .local), aiEditor: .disabled)))"
)

with open("ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift", "w") as f:
    f.write(content)
