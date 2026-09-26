import Foundation
import Security

public enum KeychainHelper: Sendable {
    public static let defaultService = "click-n-speak"
    public static let geminiAccount = "google_api_key"
    public static let openAIAccount = "openai_api_key"

    public static func setPassword(
        service: String = defaultService,
        account: String,
        password: String,
        keychainSet: @Sendable (String, String, String) throws -> Void = { s, a, p in try setRawKeychainPassword(service: s, account: a, password: p) }
    ) throws {
        try keychainSet(service, account, password)
    }

    public static func setRawKeychainPassword(service: String, account: String, password: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw NSError(domain: "KeychainHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode password string."])
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus != errSecSuccess {
                throw NSError(domain: "KeychainHelper", code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "SecItemUpdate failed: \(updateStatus)"])
            }
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw NSError(domain: "KeychainHelper", code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "SecItemAdd failed: \(addStatus)"])
            }
        default:
            throw NSError(domain: "KeychainHelper", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "SecItemCopyMatching failed: \(status)"])
        }
    }

    public static func getRawKeychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess,
              let data = dataTypeRef as? Data,
              let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            return nil
        }

        return result
    }

    public static func resolveCredential(
        service: String = defaultService,
        account: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainLookup: @Sendable (String, String) -> String? = { s, a in getRawKeychainPassword(service: s, account: a) }
    ) -> (metadata: CredentialMetadata, secret: String?) {
        if account == geminiAccount {
            if let envKey = environment["GOOGLE_API_KEY"], !envKey.isEmpty {
                return (CredentialMetadata(source: .environment(variable: "GOOGLE_API_KEY"), isConfigured: true), envKey)
            }
            if let envKey = environment["GOOGLE_GENAI_API_KEY"], !envKey.isEmpty {
                return (CredentialMetadata(source: .environment(variable: "GOOGLE_GENAI_API_KEY"), isConfigured: true), envKey)
            }
        }
        
        if let val = keychainLookup(service, account), !val.isEmpty {
            return (CredentialMetadata(source: .keychain, isConfigured: true), val)
        }
        
        return (CredentialMetadata(source: .none, isConfigured: false), nil)
    }

    public static func getMetadata(
        service: String = defaultService,
        account: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainLookup: @Sendable (String, String) -> String? = { s, a in getRawKeychainPassword(service: s, account: a) }
    ) -> CredentialMetadata {
        return resolveCredential(service: service, account: account, environment: environment, keychainLookup: keychainLookup).metadata
    }

    public static func getPassword(
        service: String = defaultService,
        account: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainLookup: @Sendable (String, String) -> String? = { s, a in getRawKeychainPassword(service: s, account: a) }
    ) -> String? {
        return resolveCredential(service: service, account: account, environment: environment, keychainLookup: keychainLookup).secret
    }

    public static func deletePassword(
        service: String = defaultService,
        account: String,
        keychainDelete: @Sendable (String, String) throws -> Void = { s, a in try deleteRawKeychainPassword(service: s, account: a) }
    ) throws {
        try keychainDelete(service, account)
    }

    public static func deleteRawKeychainPassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "KeychainHelper", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "SecItemDelete failed: \(status)"])
        }
    }
}
