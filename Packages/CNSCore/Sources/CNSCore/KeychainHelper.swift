import Foundation
import Security

public enum KeychainHelper: Sendable {
    public static let defaultService = "click-n-speak"
    public static let geminiAccount = "google_api_key"
    public static let openAIAccount = "openai_api_key"

    /// Store a password in macOS Keychain natively using Security.framework.
    public static func setPassword(
        service: String = defaultService,
        account: String,
        password: String
    ) throws {
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
            // Update existing item
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus != errSecSuccess {
                throw NSError(domain: "KeychainHelper", code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "SecItemUpdate failed: \(updateStatus)"])
            }
        case errSecItemNotFound:
            // Add new item
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

    /// Return a password from macOS Keychain natively using Security.framework.
    public static func getPassword(
        service: String = defaultService,
        account: String
    ) -> String? {
        // Special case for Gemini API key env vars, matching Python implementation
        if account == geminiAccount {
            if let envKey = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"], !envKey.isEmpty {
                return envKey
            }
            if let envKey = ProcessInfo.processInfo.environment["GOOGLE_GENAI_API_KEY"], !envKey.isEmpty {
                return envKey
            }
        }

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

    /// Delete a password from macOS Keychain natively using Security.framework.
    public static func deletePassword(
        service: String = defaultService,
        account: String
    ) throws {
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
