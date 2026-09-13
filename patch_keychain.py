import sys

with open("Packages/CNSCore/Sources/CNSCore/KeychainHelper.swift", "r") as f:
    content = f.read()

# Replace setPassword and deletePassword to use injections
new_set = """    public static func setPassword(
        service: String = defaultService,
        account: String,
        password: String,
        keychainSet: @Sendable (String, String, String) throws -> Void = { s, a, p in try setRawKeychainPassword(service: s, account: a, password: p) }
    ) throws {
        try keychainSet(service, account, password)
    }

    private static func setRawKeychainPassword(service: String, account: String, password: String) throws {
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
            if updateStatus != errSecSuccess { throw NSError(domain: "KeychainHelper", code: Int(updateStatus), userInfo: [:]) }
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus != errSecSuccess { throw NSError(domain: "KeychainHelper", code: Int(addStatus), userInfo: [:]) }
        default:
            throw NSError(domain: "KeychainHelper", code: Int(status), userInfo: [:])
        }
    }
"""

new_delete = """    public static func deletePassword(
        service: String = defaultService,
        account: String,
        keychainDelete: @Sendable (String, String) throws -> Void = { s, a in try deleteRawKeychainPassword(service: s, account: a) }
    ) throws {
        try keychainDelete(service, account)
    }

    private static func deleteRawKeychainPassword(service: String, account: String) throws {
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
"""

# The file already has setPassword and deletePassword. We need to replace them.
# I will just write a python script to replace the whole file since it's short.
