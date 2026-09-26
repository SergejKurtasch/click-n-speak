import Testing
import Foundation
@testable import CNSCore

@Suite("InitialPromptBuilder")
struct InitialPromptBuilderTests {
    private func config(_ pairs: [(String, JSONValue)]) -> JSONObject {
        JSONObject(pairs)
    }

    @Test("Empty terms yields language hint plus default context")
    func emptyTerms() {
        let cfg = config([
            ("primary_language", .string("ru")),
            ("user_terms", .object(JSONObject())),
        ])
        let prompt = InitialPromptBuilder().build(config: cfg)
        #expect(prompt == "Русский язык. Это разговорная речь. Используются профессиональные термины и аббревиатуры.")
    }

    @Test("auto_detect returns empty prompt")
    func autoDetect() {
        let cfg = config([
            ("primary_language", .string("ru")),
            ("language_auto_detect", .bool(true)),
        ])
        #expect(InitialPromptBuilder().build(config: cfg) == "")
    }

    @Test("Terms appended after language hint")
    func withTerms() {
        var userTerms = JSONObject()
        userTerms["ru"] = .array([
            .object(JSONObject([("term", .string("нейросеть")), ("source", .string("manual")), ("use_count", .int(5))])),
            .object(JSONObject([("term", .string("MLX")), ("source", .string("manual")), ("use_count", .int(2))])),
        ])
        let cfg = config([
            ("primary_language", .string("ru")),
            ("user_terms", .object(userTerms)),
        ])
        let prompt = InitialPromptBuilder().build(config: cfg)
        #expect(prompt == "Русский язык. нейросеть, MLX")
    }

    @Test("Inactive terms are skipped")
    func inactiveSkipped() {
        var userTerms = JSONObject()
        userTerms["ru"] = .array([
            .object(JSONObject([("term", .string("активный")), ("source", .string("manual"))])),
            .object(JSONObject([("term", .string("мертвый")), ("source", .string("auto")), ("inactive", .bool(true))])),
        ])
        let cfg = config([
            ("primary_language", .string("ru")),
            ("user_terms", .object(userTerms)),
        ])
        let prompt = InitialPromptBuilder().build(config: cfg)
        #expect(prompt.contains("активный"))
        #expect(!prompt.contains("мертвый"))
    }
}

@Suite("PromptTerms.parse")
struct PromptTermsTests {
    @Test("Splits on comma/newline, drops language hints")
    func parse() {
        let terms = PromptTerms.parse("Русский язык, MLX, PCA\nнейросеть")
        #expect(terms == ["MLX", "PCA", "нейросеть"])
    }

    @Test("Case-insensitive dedupe, first wins")
    func dedupe() {
        #expect(PromptTerms.parse("MLX, mlx, Mlx") == ["MLX"])
    }
}

@Suite("Paths")
struct PathsTests {
    @Test("Dev mode uses a sibling directory, never production")
    func devMode() {
        let dev = Paths(mode: .dev, environment: [:])
        #expect(dev.dataDirectory.lastPathComponent == "Click-n-speak-dev")
        #expect(dev.logFile.path.contains("Click-n-speak-dev"))
    }

    @Test("CNS_DATA_DIR override")
    func override() {
        let p = Paths(mode: .dev, environment: ["CNS_DATA_DIR": "/tmp/cns-test"])
        #expect(p.dataDirectory.path == "/tmp/cns-test")
        #expect(p.configFile.path == "/tmp/cns-test/config.json")
    }

    @Test("Release mode uses production Application Support path")
    func releaseMode() {
        let rel = Paths(mode: .release, environment: [:])
        #expect(rel.dataDirectory.path.hasSuffix("Application Support/Click-n-speak"))
        #expect(rel.logFile.path.hasSuffix("Library/Logs/Click-n-speak.log"))
    }
}

@Suite("AtomicFile & Config save")
struct AtomicFileTests {
    @Test("Write then read round-trips")
    func writeRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("config.json")
        try AtomicFile.writeText("{\n    \"a\": 1\n}", to: url)
        let read = try String(contentsOf: url, encoding: .utf8)
        #expect(read == "{\n    \"a\": 1\n}")
    }

    @Test("Config saveAtomically produces Python-compatible JSON")
    func configSave() throws {
        let value = try JSONValue.parse(#"{"autostart": true, "n": 20}"#)
        let cfg = Config(raw: value.objectValue!)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("config.json")
        try cfg.saveAtomically(to: url)
        let read = try String(contentsOf: url, encoding: .utf8)
        #expect(read == "{\n    \"autostart\": true,\n    \"n\": 20\n}")
    }
}

@Suite("Keychain compatibility contract")
struct KeychainCompatibilityTests {
    @Test("Service and account names match the Python application")
    func stableNames() {
        #expect(KeychainHelper.defaultService == "click-n-speak")
        #expect(KeychainHelper.geminiAccount == "google_api_key")
        #expect(KeychainHelper.openAIAccount == "openai_api_key")
    }
}

@Suite("SingleInstanceGuard")
struct SingleInstanceGuardTests {
    @Test("Second guard on same lock fails while first holds it")
    func exclusivity() throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-\(UUID().uuidString)").appendingPathComponent(".instance.lock")
        let first = SingleInstanceGuard(lockURL: lockURL)
        #expect(try first.acquireOrThrow())
        let second = SingleInstanceGuard(lockURL: lockURL)
        #expect(try !second.acquireOrThrow())
        first.release()
        let third = SingleInstanceGuard(lockURL: lockURL)
        #expect(third.acquire())
        third.release()
    }

    @Test("A lock file I/O failure is distinct from another running instance")
    func lockFileFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".instance.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

        let guardInstance = SingleInstanceGuard(lockURL: lockURL)
        #expect(throws: Error.self) { try guardInstance.acquireOrThrow() }
    }
}

@Suite("Validated configuration loading")
struct ValidatedConfigTests {
    @Test("Only an absent file yields defaults")
    func missingConfigReturnsDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try Config.loadValidated(from: url)
        #expect(config.schemaVersion == 10)
        #expect(config.primaryLanguage == "ru")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Malformed and non-object roots fail without altering their bytes", arguments: ["{broken", "[]", "null", "42", "\"secret\""])
    func invalidConfigIsPreserved(contents: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(contents.utf8)
        try bytes.write(to: url)
        #expect(throws: Config.LoadError.self) { try Config.loadValidated(from: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("An unreadable existing file is not treated as missing")
    func unreadableConfigThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        do {
            _ = try Config.loadValidated(from: url)
            Issue.record("Unreadable configuration returned defaults")
        } catch let error as CocoaError {
            #expect(error.code != .fileReadNoSuchFile)
            #expect(error.code == .fileReadNoPermission)
        }
    }

    @Test("Every supported schema retains unknown fields and replacement decisions", arguments: 1...10)
    func migrationsPreserveDecisions(version: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"schema_version": \(version), "future_field": {"nested": [1, "keep"]},
         "manual_replacements": [{"from": "manual", "to": "Manual"}],
         "approved_auto_replacements": [{"from": "approved", "to": "Approved"}],
         "rejected_replacements": [{"from": "rejected", "to": "Rejected"}]}
        """
        let original = try #require(JSONValue.parse(json).objectValue)
        try Data(json.utf8).write(to: url)
        let config = try Config.loadValidated(from: url)
        #expect(config.schemaVersion == 10)
        for key in ["future_field", "manual_replacements", "approved_auto_replacements", "rejected_replacements"] {
            #expect(config.raw[key] == original[key])
        }
        try config.saveAtomically(to: url)
        #expect(try Config.loadValidated(from: url) == config)
    }
}
