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

@Suite("Local Qwen real-model parity", .serialized)
struct LocalQwenGoldenTests {
    @Test("A real one-token prewarm completes before the first user cleanup")
    func prewarmBeforeFirstCleanup() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["CNS_QWEN_MODEL_DIR"])
        let gate = InferenceExecutionGate()
        let editor = LocalAiEditor(modelID: "qwen2.5-1.5b-4bit",
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true), gate: gate,
            memoryPressure: FixedMemoryPressure(high: false))
        try await editor.prepare()
        #expect(await editor.preWarm(languages: ["ru", "en"], force: true) == .warmed)
        #expect(!gate.isBusy)
        let result = await editor.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil)
        #expect(result.status == .ok || result.status == .unchanged)
        await editor.stop()
    }

    @Test("Pinned Qwen snapshot preserves the golden corpus on every cleanup outcome")
    func goldenCleanupSafety() async throws {
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
            #expect(
                result.status == .ok || result.status == .unchanged || result.status == .error,
                "case=\(item.id)"
            )
            if result.status == .error {
                #expect(result.text == item.input, "case=\(item.id)")
            }
            let folded = result.text.lowercased()
            for term in item.requiredTerms {
                #expect(folded.contains(term.lowercased()), "case=\(item.id) term=\(term)")
            }
            if result.status == .ok {
                #expect(result.text.last.map { ".!?".contains($0) } == true, "case=\(item.id)")
            }
        }

        #expect(durations.first.map { $0 <= manifest.coldMaxSeconds } == true)
        for duration in durations.dropFirst() {
            #expect(duration <= manifest.warmMaxSeconds)
        }
        await editor.stop()
    }
}
#endif
