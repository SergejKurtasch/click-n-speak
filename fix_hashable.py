import sys

with open("Packages/CNSCore/Sources/CNSCore/RuntimeDescriptors.swift", "r") as f:
    content = f.read()

content = content.replace("public enum RuntimeServiceKind: String, Sendable, Equatable, Codable", "public enum RuntimeServiceKind: String, Sendable, Hashable, Codable")
content = content.replace("public enum RuntimeReadiness: String, Sendable, Equatable, Codable", "public enum RuntimeReadiness: String, Sendable, Hashable, Codable")
content = content.replace("public struct TranscriberDescriptor: Sendable, Equatable, Codable", "public struct TranscriberDescriptor: Sendable, Hashable, Codable")
content = content.replace("public struct AiEditorDescriptor: Sendable, Equatable, Codable", "public struct AiEditorDescriptor: Sendable, Hashable, Codable")
content = content.replace("public struct RuntimeDescriptor: Sendable, Equatable, Codable", "public struct RuntimeDescriptor: Sendable, Hashable, Codable")

with open("Packages/CNSCore/Sources/CNSCore/RuntimeDescriptors.swift", "w") as f:
    f.write(content)
