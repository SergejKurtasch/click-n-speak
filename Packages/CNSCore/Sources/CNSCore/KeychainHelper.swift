import Foundation

public enum KeychainHelper: Sendable {
    public static let defaultService = "click-n-speak"
    public static let geminiAccount = "google_api_key"

    /// Store a password in macOS Keychain via the `security` CLI tool, mimicking the Python implementation.
    public static func setPassword(
        service: String = defaultService,
        account: String,
        password: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // -U: Update item if it already exists
        process.arguments = ["add-generic-password", "-s", service, "-a", account, "-w", password, "-U"]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "KeychainHelper", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "security command failed"])
        }
    }

    /// Return a password from macOS Keychain via the `security` CLI tool.
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
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return result?.isEmpty == false ? result : nil
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Delete a password from macOS Keychain via the `security` CLI tool.
    public static func deletePassword(
        service: String = defaultService,
        account: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", service, "-a", account]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Error code 44 indicates item not found, which is fine for deletion
            if process.terminationStatus != 44 {
                throw NSError(domain: "KeychainHelper", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "security command failed"])
            }
        }
    }
}
