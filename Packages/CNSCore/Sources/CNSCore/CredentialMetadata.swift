import Foundation

public enum CredentialSource: Sendable, Equatable {
    case none
    case keychain
    case environment(variable: String)
}

public struct CredentialMetadata: Sendable, Equatable {
    public let source: CredentialSource
    public let isConfigured: Bool
    
    public init(source: CredentialSource, isConfigured: Bool) {
        self.source = source
        self.isConfigured = isConfigured
    }
}
