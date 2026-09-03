#if CNS_EDITOR_MODEL_TESTS
import CNSCore
import Foundation
import Testing
@testable import CNSEditors

private struct EditorGoldenManifest: Decodable {
    struct Case: Decodable {
        let id: String
        let languages: [String]
        let input: String
        let requiredTerms: [String]

        enum CodingKeys: String, CodingKey {
            case id, languages, input
            case requiredTerms = "required_terms"
        }
    }

    let modelID: String
    let modelRevision: String
    let coldMaxSeconds: Double
    let warmMaxSeconds: Double
    let cases: [Case]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case coldMaxSeconds = "cold_max_seconds"
        case warmMaxSeconds = "warm_max_seconds"
        case cases
    }
}

@Suite("Local Qwen real-model parity")
struct LocalQwenGoldenTests {
    @Test("Pinned Qwen snapshot cleans the golden corpus within Python latency limits")
    func goldenCleanup() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["CNS_QWEN_MODEL_DIR"])
        let manifestURL = try #require(Bundle.module.url(
            forResource: "editor_golden",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let manifest = try JSONDecoder().decode(
            EditorGoldenManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        #expect(manifest.modelRevision == "8b403126fc14f14cfc99bb4cfa72ecbc129ea677")

        let editor = LocalAiEditor(
            modelID: manifest.modelID,
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true),
            gate: InferenceExecutionGate(),
            memoryPressure: FixedMemoryPressure(high: false)
        )
        try await editor.prepare()

        var durations: [Double] = []
        for item in manifest.cases {
            let started = ProcessInfo.processInfo.systemUptime
            let result = await editor.refine(
                text: item.input,
                languages: item.languages,
                knownTerms: item.requiredTerms,
                misrecognitions: nil
            )
            durations.append(ProcessInfo.processInfo.systemUptime - started)
            #expect(result.status == .ok || result.status == .unchanged, "case=\(item.id)")
            let folded = result.text.lowercased()
            for term in item.requiredTerms {
                #expect(folded.contains(term.lowercased()), "case=\(item.id) term=\(term)")
            }
            #expect(result.text.last.map { ".!?".contains($0) } == true, "case=\(item.id)")
        }

        #expect(durations.first.map { $0 <= manifest.coldMaxSeconds } == true)
        for duration in durations.dropFirst() {
            #expect(duration <= manifest.warmMaxSeconds)
        }
        await editor.stop()
    }
}
#endif
