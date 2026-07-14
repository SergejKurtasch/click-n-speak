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

@Suite("SingleInstanceGuard")
struct SingleInstanceGuardTests {
    @Test("Second guard on same lock fails while first holds it")
    func exclusivity() {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-\(UUID().uuidString)").appendingPathComponent(".instance.lock")
        let first = SingleInstanceGuard(lockURL: lockURL)
        #expect(first.acquire())
        let second = SingleInstanceGuard(lockURL: lockURL)
        #expect(!second.acquire())
        first.release()
        let third = SingleInstanceGuard(lockURL: lockURL)
        #expect(third.acquire())
        third.release()
    }
}
