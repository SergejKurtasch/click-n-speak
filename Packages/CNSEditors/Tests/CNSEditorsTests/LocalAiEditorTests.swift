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
        fileOperationTimeout: TimeInterval = 0.5,
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
            fileOperationTimeout: fileOperationTimeout,
            fileMaximumChunkCharacters: fileMaximumChunkCharacters
        )
        return (editor, directory)
    }

    @Test("Freshness expires at 300 seconds and a backwards clock invalidates it")
    func prewarmFreshnessBoundaries() async throws {
        let clock = LockedSnapshot(Date(timeIntervalSince1970: 1000))
        let generator = ScriptedLocalGenerator([])
        let directory = try EditorSnapshotFixture.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = LocalAiEditor(modelID: "qwen-test", modelDirectory: directory,
            gate: InferenceExecutionGate(), memoryPressure: FixedMemoryPressure(high: false),
            generator: generator, now: { clock.get() })
        try await editor.prepare()
        #expect(await editor.preWarm(languages: nil, force: false) == .warmed)
        clock.set(Date(timeIntervalSince1970: 1299))
        #expect(await editor.preWarm(languages: nil, force: false) == .skipped)
        clock.set(Date(timeIntervalSince1970: 1300))
        #expect(await editor.preWarm(languages: nil, force: false) == .warmed)
        clock.set(Date(timeIntervalSince1970: 1200))
        #expect(await editor.preWarm(languages: nil, force: false) == .warmed)
    }

    @Test("Failed prewarm does not mark the editor fresh")
    func prewarmFailureRemainsCold() async throws {
        let generator = ScriptedLocalGenerator([.failure])
        let (editor, directory) = try makeEditor(generator: generator)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await editor.prepare()
        #expect(await editor.preWarm(languages: nil, force: false) == .failed)
        #expect(await editor.preWarm(languages: nil, force: false) == .warmed)
    }

    @Test("Soft prewarm deadline requests cancellation and waits for actual exit")
    func prewarmDeadlineRetainsLease() async throws {
        // Use a long delay so that slow CI runners won't expire the generator before we check gate.isBusy
        let generator = ScriptedLocalGenerator([.delayed("warmup", 2.0)])
        let gate = InferenceExecutionGate()
        let directory = try EditorSnapshotFixture.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = LocalAiEditor(modelID: "qwen-test", modelDirectory: directory, gate: gate,
            memoryPressure: FixedMemoryPressure(high: false), generator: generator, prewarmTimeout: 0.01)
        try await editor.prepare()
        let task = Task { await editor.preWarm(languages: nil, force: false) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(gate.isBusy)
        #expect(await task.value == .skipped)
        #expect(!gate.isBusy)
        #expect(await editor.preWarm(languages: nil, force: false) == .warmed)
    }

    @Test("Successful synthetic computation selects the existing warm user deadline")
    func prewarmSelectsWarmUserTimeout() async throws {
        let generator = ScriptedLocalGenerator([.output("warmup"), .delayed(longEditorInput, 0.08)])
        let directory = try EditorSnapshotFixture.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = InferenceExecutionGate()
        let editor = LocalAiEditor(modelID: "qwen-test", modelDirectory: directory,
            gate: gate, memoryPressure: FixedMemoryPressure(high: false),
            generator: generator, realtimeWarmTimeout: 0.02, realtimeColdTimeout: 0.20)
        try await editor.prepare()
        #expect(await editor.preWarm(languages: nil, force: true) == .warmed)
        #expect(await editor.refine(text: longEditorInput, languages: nil, knownTerms: nil, misrecognitions: nil).status == .timeout)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !gate.isBusy { break }
        }
    }

    @Test("Successful file cleanup refreshes prewarm freshness")
    func fileCleanupRefreshesPrewarmFreshness() async throws {
        let generator = ScriptedLocalGenerator([.output(longEditorInput)])
        let (editor, directory) = try makeEditor(generator: generator)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await editor.prepare()
        #expect(await editor.refineFileText(text: longEditorInput, languages: nil, knownTerms: nil, misrecognitions: nil).status == .unchanged)
        #expect(await editor.preWarm(languages: nil, force: false) == .skipped)
        #expect(await generator.preWarmCount == 0)
    }

    @Test("Cancelled file cleanup does not refresh prewarm freshness")
    func cancelledFileCleanupDoesNotRefreshPrewarmFreshness() async throws {
        let generator = ScriptedLocalGenerator([.delayed(longEditorInput, 0.10)])
        let (editor, directory) = try makeEditor(
            generator: generator,
            fileOperationTimeout: 0.01
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await editor.prepare()

        #expect(
            await editor.refineFileText(
                text: longEditorInput,
                languages: nil,
                knownTerms: nil,
                misrecognitions: nil
            ).status == .timeout
        )
        // Wait for the uncooperative generator to finish and release the lease.
        // A slow CI runner might delay the generator's global queue completion.
        var warmed = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if await editor.preWarm(languages: nil, force: false) == .warmed {
                warmed = true
                break
            }
        }
        #expect(warmed, "Prewarm should eventually succeed after lease is released")
        #expect(await generator.preWarmCount == 1)
    }

    @Test("Prepared local prewarm computes once and forced wake bypasses freshness")
    func prewarmComputesAndTracksFreshness() async throws {
        let generator = ScriptedLocalGenerator([])
        let gate = InferenceExecutionGate()
        let (editor, directory) = try makeEditor(generator: generator, gate: gate)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await editor.preWarm(languages: ["en"], force: true) == .skipped)
        try await editor.prepare()
        #expect(await editor.preWarm(languages: ["en"], force: false) == .warmed)
        #expect(await editor.preWarm(languages: ["en"], force: false) == .skipped)
        #expect(await editor.preWarm(languages: ["en"], force: true) == .warmed)
        #expect(await generator.preWarmCount == 2)
        #expect(!gate.isBusy)
    }

    @Test("Prewarm yields to shared inference and memory pressure")
    func prewarmSkipsBusyGateAndMemoryPressure() async throws {
        for memoryHigh in [false, true] {
            let generator = ScriptedLocalGenerator([])
            let gate = InferenceExecutionGate()
            let (editor, directory) = try makeEditor(generator: generator, gate: gate, memoryHigh: memoryHigh)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await editor.prepare()
            let lease = memoryHigh ? nil : gate.tryAcquire()
            #expect(await editor.preWarm(languages: nil, force: true) == .skipped)
            #expect(await generator.preWarmCount == 0)
            lease?.release()
        }
    }

    @Test("Cancelled prewarm retains the lease until uncooperative generation exits")
    func cancelledPrewarmRetainsLease() async throws {
        // Use a long delay so that slow CI runners won't expire the generator before we check gate.isBusy
        let generator = ScriptedLocalGenerator([.delayed("warmup", 2.0)])
        let gate = InferenceExecutionGate()
        let (editor, directory) = try makeEditor(generator: generator, gate: gate)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await editor.prepare()
        let task = Task { await editor.preWarm(languages: nil, force: true) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        #expect(gate.isBusy)
        #expect(await task.value != .warmed)
        #expect(!gate.isBusy)
        #expect(await editor.preWarm(languages: nil, force: false) == .warmed)
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

        // Wait for the uncooperative generator to finish and release the lease.
        var released = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if !gate.isBusy {
                released = true
                break
            }
        }
        #expect(released, "Gate should eventually be released")
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
            fileGateTimeout: 10
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

    @Test("Cancelling active file refinement reaches the local generator")
    func activeFileCancellationReachesGenerator() async throws {
        let generator = ScriptedLocalGenerator([.waitForCancellation])
        let (editor, directory) = try makeEditor(generator: generator)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await editor.prepare()
        let task = Task {
            await editor.refineFileText(
                text: longEditorInput,
                languages: ["en"],
                knownTerms: nil,
                misrecognitions: nil
            )
        }
        while await generator.callCount == 0 { await Task.yield() }

        task.cancel()
        let result = await task.value
        while await generator.cancellationCount == 0 { await Task.yield() }

        #expect(result.text == longEditorInput)
        #expect(result.status == .timeout)
        #expect(await generator.cancellationCount == 1)
    }
}
