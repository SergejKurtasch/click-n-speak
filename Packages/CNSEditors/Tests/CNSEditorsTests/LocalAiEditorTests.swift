import CNSCore
import Foundation
import Testing
@testable import CNSEditors

@Suite("Local AI editor")
struct LocalAiEditorTests {
    private func makeEditor(
        generator: ScriptedLocalGenerator,
        gate: InferenceExecutionGate = InferenceExecutionGate(),
        memoryHigh: Bool = false,
        warmTimeout: TimeInterval = 0.2,
        coldTimeout: TimeInterval = 0.2,
        fileGateTimeout: TimeInterval = 0.2,
        fileMaximumChunkCharacters: Int = EditorPolicy.localMaximumFileChunkCharacters
    ) throws -> (LocalAiEditor, URL) {
        let directory = try EditorSnapshotFixture.make()
        let editor = LocalAiEditor(
            modelID: "qwen-test",
            modelDirectory: directory,
            gate: gate,
            memoryPressure: FixedMemoryPressure(high: memoryHigh),
            generator: generator,
            realtimeWarmTimeout: warmTimeout,
            realtimeColdTimeout: coldTimeout,
            coldIdleThreshold: 0,
            fileGateTimeout: fileGateTimeout,
            fileOperationTimeout: 0.5,
            fileMaximumChunkCharacters: fileMaximumChunkCharacters
        )
        return (editor, directory)
    }

    @Test("Disabled, skipped, memory-pressure, unchanged, ok, and error paths preserve the source contract")
    func statusMatrix() async throws {
        let disabledGenerator = ScriptedLocalGenerator([.output(longEditorInput)])
        let (disabled, disabledDirectory) = try makeEditor(generator: disabledGenerator)
        #expect(await disabled.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil).status == .disabled)
        try? FileManager.default.removeItem(at: disabledDirectory)

        let shortGenerator = ScriptedLocalGenerator([.output("unused")])
        let (short, shortDirectory) = try makeEditor(generator: shortGenerator)
        try await short.prepare()
        #expect(await short.refine(text: "short phrase", languages: ["en"], knownTerms: nil, misrecognitions: nil).status == .skipped)
        #expect(await shortGenerator.callCount == 0)
        try? FileManager.default.removeItem(at: shortDirectory)

        let pressureGenerator = ScriptedLocalGenerator([.output("unused")])
        let (pressured, pressureDirectory) = try makeEditor(
            generator: pressureGenerator,
            memoryHigh: true
        )
        try await pressured.prepare()
        #expect(await pressured.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil).status == .memoryPressure)
        try? FileManager.default.removeItem(at: pressureDirectory)

        let unchangedGenerator = ScriptedLocalGenerator([.output(longEditorInput)])
        let (unchanged, unchangedDirectory) = try makeEditor(generator: unchangedGenerator)
        try await unchanged.prepare()
        let unchangedResult = await unchanged.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil)
        #expect(unchangedResult == RefineResult(text: longEditorInput, status: .unchanged))
        try? FileManager.default.removeItem(at: unchangedDirectory)

        let improved = longEditorInput + "."
        let okGenerator = ScriptedLocalGenerator([.output(improved)])
        let (ok, okDirectory) = try makeEditor(generator: okGenerator)
        try await ok.prepare()
        #expect(await ok.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil) == RefineResult(text: improved, status: .ok))
        try? FileManager.default.removeItem(at: okDirectory)

        let errorGenerator = ScriptedLocalGenerator([.failure])
        let (failed, failedDirectory) = try makeEditor(generator: errorGenerator)
        try await failed.prepare()
        #expect(await failed.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil) == RefineResult(text: longEditorInput, status: .error))
        try? FileManager.default.removeItem(at: failedDirectory)
    }

    @Test("A realtime timeout returns the original while the worker keeps the Metal lease")
    func timeoutRetainsLease() async throws {
        let gate = InferenceExecutionGate()
        let generator = ScriptedLocalGenerator([.delayed(longEditorInput + ".", 0.12)])
        let (editor, directory) = try makeEditor(
            generator: generator,
            gate: gate,
            warmTimeout: 0.02,
            coldTimeout: 0.02
        )
        try await editor.prepare()

        let first = await editor.refine(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(first == RefineResult(text: longEditorInput, status: .timeout))
        #expect(gate.isBusy)
        let second = await editor.refine(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(second.status == .skipped)

        try await Task.sleep(for: .milliseconds(140))
        #expect(!gate.isBusy)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("Local preparation cannot overlap an active inference lease")
    func preparationRespectsSharedGate() async throws {
        let gate = InferenceExecutionGate()
        let lease = try #require(gate.tryAcquire())
        let generator = ScriptedLocalGenerator([.output("unused")])
        let (editor, directory) = try makeEditor(
            generator: generator,
            gate: gate,
            fileGateTimeout: 0.02
        )
        await #expect(throws: LocalAiEditorError.inferenceBusy) {
            try await editor.prepare()
        }
        #expect(!editor.isReady)
        lease.release()
        try await editor.prepare()
        #expect(editor.isReady)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("Whisper ownership skips local Qwen, while cancellation releases a waiting file request")
    func sharedGateAndFileCancellation() async throws {
        let gate = InferenceExecutionGate()
        let generator = ScriptedLocalGenerator([.output(longEditorInput + ".")])
        let (editor, directory) = try makeEditor(
            generator: generator,
            gate: gate,
            fileGateTimeout: 1
        )
        try await editor.prepare()
        let whisperLease = try #require(gate.tryAcquire())

        let realtime = await editor.refine(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(realtime.status == .skipped)

        let fileTask = Task {
            await editor.refineFileText(
                text: longEditorInput,
                languages: ["en"],
                knownTerms: nil,
                misrecognitions: nil
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        fileTask.cancel()
        #expect(await fileTask.value.status == .skipped)
        whisperLease.release()
        #expect(!gate.isBusy)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("File chunks preserve order and use the local file prompt")
    func fileOrdering() async throws {
        let source = "First complete sentence. Second complete sentence. Third complete sentence."
        let generator = ScriptedLocalGenerator([.output("First complete sentence!"), .output("Second complete sentence!"), .output("Third complete sentence!")])
        let (editor, directory) = try makeEditor(
            generator: generator,
            fileMaximumChunkCharacters: 34
        )
        try await editor.prepare()

        let result = await editor.refineFileText(
            text: source,
            languages: ["en"],
            knownTerms: ["MLX"],
            misrecognitions: nil
        )
        #expect(result.status == .ok)
        #expect(result.text == "First complete sentence!\n\nSecond complete sentence!\n\nThird complete sentence!")
        #expect(await generator.callCount == 3)
        let prompts = await generator.prompts
        #expect(prompts.first?.contains("Fix punctuation and capitalisation") == true)
        try? FileManager.default.removeItem(at: directory)
    }
}
