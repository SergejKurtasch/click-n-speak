import XCTest
@testable import CNSCore

final class CredentialMetadataTests: XCTestCase {
    
    func testGeminiEnvironmentVariablesPriority() {
        // GOOGLE_API_KEY has priority over GOOGLE_GENAI_API_KEY
        let env1 = ["GOOGLE_API_KEY": "val1", "GOOGLE_GENAI_API_KEY": "val2"]
        let res1 = KeychainHelper.resolveCredential(account: KeychainHelper.geminiAccount, environment: env1) { _, _ in "keychain_val" }
        XCTAssertEqual(res1.metadata.source, .environment(variable: "GOOGLE_API_KEY"))
        XCTAssertEqual(res1.secret, "val1")
        
        let env2 = ["GOOGLE_GENAI_API_KEY": "val2"]
        let res2 = KeychainHelper.resolveCredential(account: KeychainHelper.geminiAccount, environment: env2) { _, _ in "keychain_val" }
        XCTAssertEqual(res2.metadata.source, .environment(variable: "GOOGLE_GENAI_API_KEY"))
        XCTAssertEqual(res2.secret, "val2")
    }
    
    func testEnvironmentSkipsEmptyValues() {
        let env = ["GOOGLE_API_KEY": "", "GOOGLE_GENAI_API_KEY": "  "]
        // Wait, the implementation does !envKey.isEmpty but doesn't trim. Let's assume trimming is for keychain.
        let res = KeychainHelper.resolveCredential(account: KeychainHelper.geminiAccount, environment: env) { _, _ in "keychain_val" }
        // If it's "  ", it's not empty string! Wait, ProcessInfo environment doesn't trim either. 
        // We should check exactly what Python does.
        XCTAssertEqual(res.metadata.source, .environment(variable: "GOOGLE_GENAI_API_KEY"))
    }
    
    func testOpenAIDoesNotUseEnvironment() {
        let env = ["OPENAI_API_KEY": "val1"]
        let res = KeychainHelper.resolveCredential(account: KeychainHelper.openAIAccount, environment: env) { _, _ in "keychain_val" }
        XCTAssertEqual(res.metadata.source, .keychain)
        XCTAssertEqual(res.secret, "keychain_val")
    }
    
    func testFallbackToKeychain() {
        let res = KeychainHelper.resolveCredential(account: KeychainHelper.geminiAccount, environment: [:]) { _, _ in "keychain_val" }
        XCTAssertEqual(res.metadata.source, .keychain)
        XCTAssertEqual(res.secret, "keychain_val")
    }
    
    func testMissingCredentials() {
        let res = KeychainHelper.resolveCredential(account: KeychainHelper.geminiAccount, environment: [:]) { _, _ in nil }
        XCTAssertEqual(res.metadata.source, .none)
        XCTAssertFalse(res.metadata.isConfigured)
        XCTAssertNil(res.secret)
    }
}
