import Foundation
import Testing
@testable import CNSCore

@Suite("Python ↔ Swift data compatibility")
struct ParityDataCompatibilityTests {
    private static let fixedNow = "2026-07-14T12:00:00.123456+00:00"

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("tests/parity/swift_parity_scenarios.json").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func schemaFixtures(repositoryRoot: URL) throws -> [[String: Any]] {
        let url = repositoryRoot.appendingPathComponent("tests/parity/fixtures/config_schemas.json")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return try #require(root["fixtures"] as? [[String: Any]])
    }

    private func runPythonBridge(
        repositoryRoot: URL,
        input: URL,
        output: URL,
        markUpdate: Bool = false
    ) throws {
        let python = repositoryRoot.appendingPathComponent("venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = repositoryRoot
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/parity_config_bridge.py").path,
            "--input", input.path,
            "--output", output.path,
        ] + (markUpdate ? ["--mark-python-update"] : [])
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "Python bridge failed: \(diagnostic)")
        if process.terminationStatus != 0 {
            throw CocoaError(.executableRuntimeMismatch)
        }
    }

    @Test("Every supported schema round-trips Python → Swift → Python")
    func pythonSwiftPythonRoundTrip() throws {
        let root = try repositoryRoot()
        let fixtures = try schemaFixtures(repositoryRoot: root)
        #expect(Set(fixtures.compactMap { $0["id"] as? String }).count == 10)

        for fixture in fixtures {
            let fixtureID = try #require(fixture["id"] as? String)
            let rawConfig = try #require(fixture["config"] as? [String: Any])
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("cns-parity-\(fixtureID)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let original = temporary.appendingPathComponent("original.json")
            try JSONSerialization.data(withJSONObject: rawConfig, options: [.prettyPrinted])
                .write(to: original)
            let pythonMigrated = temporary.appendingPathComponent("python-migrated.json")
            try runPythonBridge(repositoryRoot: root, input: original, output: pythonMigrated)

            let swiftLoaded = Config.load(from: pythonMigrated)
            #expect(swiftLoaded.schemaVersion == 10, "Python output did not load as v10 for \(fixtureID)")
            #expect(swiftLoaded.raw["future_extension"]?.objectValue?["owner"]?.stringValue == "parity")
            let swiftSaved = temporary.appendingPathComponent("swift-saved.json")
            try swiftLoaded.saveAtomically(to: swiftSaved)

            let pythonReloaded = temporary.appendingPathComponent("python-reloaded.json")
            try runPythonBridge(
                repositoryRoot: root,
                input: swiftSaved,
                output: pythonReloaded,
                markUpdate: true
            )
            let finalSwiftLoad = Config.load(from: pythonReloaded)
            #expect(finalSwiftLoad.schemaVersion == 10)
            #expect(finalSwiftLoad.raw["parity_python_update"]?.boolValue == true)
            #expect(finalSwiftLoad.raw["future_extension"]?.objectValue?["owner"]?.stringValue == "parity")
        }
    }

    @Test("Every supported schema round-trips Swift → Python → Swift")
    func swiftPythonSwiftRoundTrip() throws {
        let root = try repositoryRoot()
        for fixture in try schemaFixtures(repositoryRoot: root) {
            let fixtureID = try #require(fixture["id"] as? String)
            let rawConfig = try #require(fixture["config"] as? [String: Any])
            let json = try JSONSerialization.data(withJSONObject: rawConfig)
            let value = try JSONValue.parse(data: json)
            let object = try #require(value.objectValue)
            let swiftConfig = Config.migrated(object, now: Self.fixedNow)

            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("cns-parity-reverse-\(fixtureID)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let swiftSaved = temporary.appendingPathComponent("swift.json")
            try swiftConfig.saveAtomically(to: swiftSaved)
            let pythonSaved = temporary.appendingPathComponent("python.json")
            try runPythonBridge(
                repositoryRoot: root,
                input: swiftSaved,
                output: pythonSaved,
                markUpdate: true
            )

            let reloaded = Config.load(from: pythonSaved)
            #expect(reloaded.schemaVersion == 10)
            #expect(reloaded.raw["parity_python_update"]?.boolValue == true)
            #expect(reloaded.raw["future_extension"]?.objectValue?["owner"]?.stringValue == "parity")
        }
    }

    @Test("Malformed migration input remains byte-for-byte recoverable")
    func malformedOriginalIsUntouched() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-corrupt-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let corrupt = Data("{not valid json".utf8)
        try corrupt.write(to: temporary)

        let fallback = Config.load(from: temporary)
        #expect(fallback.schemaVersion == 10)
        #expect(try Data(contentsOf: temporary) == corrupt)
    }
}
