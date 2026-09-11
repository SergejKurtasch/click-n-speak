import CNSCore
import CNSDictionary
import CNSTranscription

import Foundation
import Testing
@testable import CNSSession

@MainActor
@Suite("SessionController")
struct SessionControllerTests {
    // MARK: - Fixture

    private struct Rig {
        let controller: SessionController
        let panel: FakePanel
        let recorder: FakeRecorder
        let transcriber: FakeTranscriber
        let delivery: FakeDelivery
        let frontmost: FakeFrontmost
        let aiEditor: FakeAiEditor?
    }

    private func makeRig(
        texts: [String] = ["распознанный текст"],
        results: [TranscriptionResult] = [],
        delay: TimeInterval = 0,
        config: Config? = nil,
        aiEditor: FakeAiEditor? = nil,
        phraseHistory: (any PhraseHistoryProviding)? = nil,
        datasetLogger: DatasetLogger? = nil,
        dictionaryCoordinator: (any DictionaryCoordinating)? = nil,
        runtimeDescriptorProvider: (@Sendable () -> RuntimeDescriptor)? = nil,
        shutdownTimeout: TimeInterval = 10,
        onConfigChanged: @escaping (Config) -> Void = { _ in },
        onPhraseHistoryChanged: @escaping () -> Void = {}
    ) -> Rig {
        let panel = FakePanel()
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(texts: texts, results: results, delay: delay)
        let delivery = FakeDelivery()
        let frontmost = FakeFrontmost()
        let controller = SessionController(
            config: config ?? Self.makeConfig(),
            transcriber: transcriber,
            aiEditor: aiEditor,
            recorder: recorder,
            panel: panel,
            delivery: delivery,
            frontmost: frontmost,
            phraseHistory: phraseHistory,
            datasetLogger: datasetLogger,
            dictionaryCoordinator: dictionaryCoordinator,
            shutdownTimeout: shutdownTimeout,
            onConfigChanged: onConfigChanged,
            runtimeDescriptorProvider: runtimeDescriptorProvider,
            onPhraseHistoryChanged: onPhraseHistoryChanged
        )
        return Rig(
            controller: controller, panel: panel, recorder: recorder,
            transcriber: transcriber, delivery: delivery, frontmost: frontmost,
            aiEditor: aiEditor
        )
    }

    private static func makeConfig(
        primary: String = "ru",
        additional: [String] = ["en"],
        autoDetect: Bool = false
    ) -> Config {
        var obj = JSONObject()
        obj["schema_version"] = .int(9)
        obj["primary_language"] = .string(primary)
        obj["additional_languages"] = .array(additional.map { .string($0) })
        obj["language_auto_detect"] = .bool(autoDetect)
        obj["initial_prompt"] = .string("Русский язык. Whisper")
        return Config(raw: obj)
    }

    private let audio = [Float](repeating: 0.2, count: 16000)

    /// Run one full cycle: hotkey on, chunk, hotkey off, worker drains.
    private func runSession(_ rig: Rig, chunks: [[Float]]? = nil, final: [Float]? = nil) async {
        rig.controller.toggle(now: Date())
        await settle()
        rig.recorder.scriptedChunks = chunks ?? []
        rig.recorder.finalChunk = final ?? audio
        rig.controller.toggle(now: Date().addingTimeInterval(1))
        await settle()
    }

    /// Let the controller's detached tasks reach their next await.
    private func settle(_ rounds: Int = 12) async {
        for _ in 0..<rounds {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - Happy path

    @Test("A full cycle shows the HUD, then the editable popup")
    func fullCycle() async {
        let rig = makeRig()
        await runSession(rig)

        #expect(rig.panel.events.first == .show("Recording…"))
        #expect(rig.panel.statuses.contains("Transcribing…"))
        #expect(rig.panel.interactiveTexts == ["распознанный текст"])
        #expect(rig.controller.isRecording == false)
        #expect(rig.controller.isProcessing == false)
        #expect(rig.controller.sessionId == 1)
    }

    @Test("Non-final chunks stream into the HUD as they decode")
    func streamsPartials() async {
        let rig = makeRig(texts: ["первая часть", "вторая часть"])

        rig.controller.toggle(now: Date())
        await settle()
        rig.recorder.emitChunk(audio)
        await settle()

        #expect(rig.panel.events.contains(.text("первая часть")))

        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: Date().addingTimeInterval(1))
        await settle()
        #expect(rig.panel.interactiveTexts == ["первая часть вторая часть"])
    }

    @Test("Audio configuration change preserves partial text with an incomplete warning")
    func audioConfigurationChangePreservesPartialDraft() async {
        let rig = makeRig(texts: ["partial capture"])
        rig.controller.toggle(now: Date())
        await settle()
        rig.recorder.emitChunk(audio)
        await rig.transcriber.waitUntilRequestCount(1)

        rig.recorder.emitConfigurationChange()
        rig.controller.toggle(now: Date().addingTimeInterval(1))
        await settle(80)

        #expect(rig.controller.isRecording == false)
        #expect(rig.controller.isProcessing == false)
        #expect(rig.panel.interactiveTexts == ["partial capture"])
        #expect(rig.panel.incompleteWarnings.count == 1)
    }

    @Test("Confirming injects into the app that was frontmost at start")
    func confirmInjects() async {
        let rig = makeRig()
        rig.frontmost.pid = 777
        await runSession(rig)

        rig.panel.userConfirms("исправленный текст")
        await settle(200)  // the injection path deliberately waits 0.2 s first

        #expect(rig.delivery.delivered.count == 1)
        #expect(rig.delivery.delivered.first?.text == "исправленный текст ")
        #expect(rig.delivery.delivered.first?.pid == 777)
    }

    @Test("A confirmed phrase invalidates shared history exactly once")
    func historyInvalidatesOnce() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = PhraseHistory(fileURL: directory.appendingPathComponent("phrases.txt"))
        var invalidations = 0
        let rig = makeRig(
            phraseHistory: history,
            onPhraseHistoryChanged: { invalidations += 1 }
        )
        await runSession(rig)

        rig.panel.userConfirms("saved phrase")
        rig.panel.userConfirms("duplicate callback")
        await settle()

        #expect(invalidations == 1)
        #expect(history.count() == 1)
        #expect(history.lastPhrases(1).first?.text == "saved phrase")
    }

    @Test("Confirmation metadata is handed to the dictionary coordinator exactly once")
    func coordinatorConfirmIsExactlyOnce() async {
        let coordinator = FakeDictionaryCoordinator(config: Self.makeConfig())
        var historyInvalidations = 0
        let rig = makeRig(
            dictionaryCoordinator: coordinator,
            onPhraseHistoryChanged: { historyInvalidations += 1 }
        )
        await runSession(rig)

        rig.panel.userConfirms("final text")
        rig.panel.userConfirms("duplicate callback")
        await settle()

        #expect(coordinator.confirmations.count == 1)
        #expect(coordinator.confirmations.first?.sessionID == 1)
        #expect(coordinator.confirmations.first?.datasetRecord.userFinal == "final text")
        #expect(historyInvalidations == 1)
    }

    @Test("Cancelling injects nothing")
    func cancelInjectsNothing() async {
        let rig = makeRig()
        await runSession(rig)

        rig.panel.userCancels()
        await settle()

        #expect(rig.delivery.delivered.isEmpty)
    }

    @Test("Confirming an emptied popup injects nothing")
    func emptyConfirmInjectsNothing() async {
        let rig = makeRig()
        await runSession(rig)

        rig.panel.userConfirms("")
        await settle()

        #expect(rig.delivery.delivered.isEmpty)
    }

    @Test("A failed delivery restores the confirmed draft and can be retried")
    func failedDeliveryRestoresDraft() async {
        let rig = makeRig()
        rig.delivery.outcome = .failed(.targetUnavailable)
        await runSession(rig)

        rig.panel.userConfirms("keep this text")
        await settle(200)

        #expect(rig.controller.state == .popup(sessionID: 1, targetPID: 4242))
        #expect(rig.controller.popupDraft != nil)
        #expect(rig.panel.isShowingInteractive)
        #expect(rig.panel.interactiveTexts.last == "keep this text")

        rig.delivery.outcome = .delivered
        rig.panel.userConfirms()
        await settle(200)

        #expect(rig.delivery.delivered.count == 2)
        #expect(rig.controller.state == .idle)
        #expect(rig.controller.popupDraft == nil)
    }

    // MARK: - Append mode

    @Test("The hotkey over an open popup appends and keeps the target app")
    func appendsToOpenPopup() async {
        let rig = makeRig(texts: ["первая фраза", "вторая фраза"])
        rig.frontmost.pid = 100
        await runSession(rig)
        #expect(rig.panel.isShowingInteractive == true)

        // Our own popup is frontmost now — the captured pid must not change.
        rig.frontmost.pid = 999
        rig.controller.toggle(now: Date().addingTimeInterval(2))
        await settle()
        #expect(rig.controller.appendToPopup == true)

        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: Date().addingTimeInterval(3))
        await settle()

        #expect(rig.panel.events.contains(.append("вторая фраза")))
        #expect(rig.panel.interactiveTexts.count == 1)  // no second popup
        #expect(rig.controller.previousAppPid == 100)
        #expect(rig.controller.appendToPopup == false)
    }

    @Test("Appending silence preserves the editable first phrase")
    func silentAppendPreservesPopup() async {
        let rig = makeRig(texts: ["first", ""])
        let base = Date()
        await runSession(rig)

        rig.controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(3))
        await settle()

        #expect(rig.panel.isShowingInteractive)
        #expect(rig.panel.decisionEnabled)
        #expect(rig.panel.shownText == "first")
        await rig.controller.shutdown()
    }

    @Test("Append confirmation keeps raw text from every recording")
    func appendPreservesDatasetSource() async {
        let coordinator = FakeDictionaryCoordinator(config: Self.makeConfig())
        let rig = makeRig(
            texts: ["first", "second"],
            dictionaryCoordinator: coordinator
        )
        let base = Date()
        await runSession(rig)
        rig.controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(3))
        await settle()

        rig.panel.userConfirms()
        await settle()

        #expect(coordinator.confirmations.count == 1)
        #expect(coordinator.confirmations.first?.datasetRecord.rawWhisper == "first second")
        #expect(coordinator.confirmations.first?.datasetRecord.userFinal == "first second")
        await rig.controller.shutdown()
    }

    @Test("Append keeps a user-edited first segment separate from raw provenance")
    func appendAfterUserEditPreservesProvenance() async {
        let coordinator = FakeDictionaryCoordinator(config: Self.makeConfig())
        let rig = makeRig(
            texts: ["first", "second"],
            dictionaryCoordinator: coordinator
        )
        let base = Date()
        await runSession(rig)
        rig.panel.userEdits("corrected first")

        rig.controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(3))
        await settle()
        rig.panel.userConfirms()
        await settle()

        #expect(coordinator.confirmations.first?.datasetRecord.rawWhisper == "first second")
        #expect(coordinator.confirmations.first?.datasetRecord.userFinal == "corrected first second")
        await rig.controller.shutdown()
    }

    @Test("A recorder start failure while appending restores the existing draft")
    func failedAppendStartPreservesDraft() async {
        let rig = makeRig(texts: ["first"])
        await runSession(rig)
        rig.recorder.startError = RecorderErrorStub.failed

        rig.controller.toggle(now: Date().addingTimeInterval(2))
        await settle()

        #expect(rig.panel.isShowingInteractive)
        #expect(rig.panel.decisionEnabled)
        #expect(rig.panel.shownText == "first")
        await rig.controller.shutdown()
    }

    @Test("Enter and Escape cannot destroy a draft while append is active")
    func appendDisablesPopupDecisions() async {
        let rig = makeRig(texts: ["first", "second"])
        let base = Date()
        await runSession(rig)

        rig.controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        rig.panel.userConfirms()
        rig.panel.userCancels()

        #expect(rig.panel.isShowingInteractive)
        #expect(!rig.panel.decisionEnabled)
        #expect(rig.panel.shownText == "first")
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(3))
        await settle()
        #expect(rig.panel.isShowingInteractive)
        #expect(rig.panel.decisionEnabled)
        #expect(rig.panel.shownText == "first second")
        await rig.controller.shutdown()
    }

    @Test("Two appended recordings produce one confirmation with three raw segments")
    func twoAppendsProduceOneConfirmation() async {
        let coordinator = FakeDictionaryCoordinator(config: Self.makeConfig())
        let rig = makeRig(
            texts: ["first", "second", "third"],
            dictionaryCoordinator: coordinator
        )
        let base = Date()
        await runSession(rig)
        for index in 0..<2 {
            let offset = Double(index * 2 + 2)
            rig.controller.toggle(now: base.addingTimeInterval(offset))
            await settle()
            rig.recorder.finalChunk = audio
            rig.controller.toggle(now: base.addingTimeInterval(offset + 1))
            await settle()
        }

        rig.panel.userConfirms()
        rig.panel.userConfirms("duplicate")
        await settle()

        #expect(coordinator.confirmations.count == 1)
        #expect(coordinator.confirmations.first?.datasetRecord.rawWhisper == "first second third")
        #expect(coordinator.confirmations.first?.datasetRecord.segments?.count == 3)
        await rig.controller.shutdown()
    }

    @Test("A multi-segment draft never claims one aggregate AI edit")
    func appendedDraftHasNoAggregateAiEdit() async {
        var config = Self.makeConfig()
        config.raw["ai_editor_enabled"] = .bool(true)
        let editor = FakeAiEditor()
        let coordinator = FakeDictionaryCoordinator(config: config)
        let rig = makeRig(
            texts: ["first", "second"],
            config: config,
            aiEditor: editor,
            dictionaryCoordinator: coordinator
        )
        let base = Date()
        await runSession(rig)
        rig.controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(3))
        await settle()

        rig.panel.userConfirms()
        await settle()

        #expect(coordinator.confirmations.first?.datasetRecord.aiEdited == nil)
        #expect(coordinator.confirmations.first?.datasetRecord.segments?.count == 2)
        await rig.controller.shutdown()
    }

    @Test("A failed middle chunk keeps useful text and shows an incomplete warning")
    func partialFailureIsVisible() async {
        let failure = TranscriptionFailure(kind: .decode, message: "Decode failed")
        let coordinator = FakeDictionaryCoordinator(config: Self.makeConfig())
        let rig = makeRig(
            results: [
                TranscriptionResult(text: "first"),
                .failed(failure),
                TranscriptionResult(text: "third"),
            ],
            dictionaryCoordinator: coordinator
        )

        await runSession(rig, chunks: [audio, audio], final: audio)

        #expect(rig.panel.shownText == "first third")
        #expect(rig.panel.incompleteWarnings == ["Incomplete transcription"])
        #expect(rig.controller.popupDraft?.failedChunkIndices == [1])
        rig.panel.userConfirms()
        await settle()
        #expect(coordinator.confirmations.first?.datasetRecord.incomplete == true)
        await rig.controller.shutdown()
    }

    @Test("Timeout and abort outcomes label a useful draft incomplete")
    func exceptionalEmptyOutcomesWarn() async {
        for outcome in [TranscriptionOutcome.timedOut, .aborted] {
            let rig = makeRig(results: [
                TranscriptionResult(text: "first"),
                TranscriptionResult(text: "", outcome: outcome),
                TranscriptionResult(text: "third"),
            ])

            await runSession(rig, chunks: [audio, audio], final: audio)

            #expect(rig.panel.shownText == "first third")
            #expect(rig.panel.incompleteWarnings == ["Incomplete transcription"])
            #expect(rig.controller.popupDraft?.failedChunkIndices == [1])
            await rig.controller.shutdown()
        }
    }

    @Test("A failed empty append restores the draft with a monotonic failed index")
    func failedEmptyAppendWarns() async {
        let rig = makeRig(results: [
            TranscriptionResult(text: "first"),
            TranscriptionResult(text: "", outcome: .timedOut),
        ])
        let base = Date()
        await runSession(rig)

        rig.controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(3))
        await settle()

        #expect(rig.panel.shownText == "first")
        #expect(rig.panel.isShowingInteractive)
        #expect(rig.panel.incompleteWarnings == ["Incomplete transcription"])
        #expect(rig.controller.popupDraft?.failedChunkIndices == [1])
        await rig.controller.shutdown()
    }

    @Test("Routine speech guards do not label a useful draft incomplete")
    func routineGuardsDoNotWarn() async {
        for outcome in [
            TranscriptionOutcome.noSpeech,
            .guarded(.silentShortChunk),
            .guarded(.hallucination),
        ] {
            let rig = makeRig(results: [
                TranscriptionResult(text: "first"),
                TranscriptionResult(text: "", outcome: outcome),
                TranscriptionResult(text: "third"),
            ])

            await runSession(rig, chunks: [audio, audio], final: audio)

            #expect(rig.panel.shownText == "first third")
            #expect(rig.panel.incompleteWarnings.isEmpty)
            #expect(rig.controller.popupDraft?.failedChunkIndices.isEmpty == true)
            await rig.controller.shutdown()
        }
    }

    @Test("Audio backlog overflow stops capture once and drains accepted chunks")
    func backlogOverflowStopsAndDrains() async {
        let rig = makeRig(texts: ["first", "second"])
        let base = Date()
        rig.controller.toggle(now: base)
        await settle()
        await rig.transcriber.suspendOneDecode()

        let sixtySeconds = [Float](repeating: 0.2, count: 60 * 16_000)
        rig.recorder.emitChunk(sixtySeconds)
        await rig.transcriber.waitUntilRequestCount(1)
        rig.recorder.emitChunk(sixtySeconds)
        rig.recorder.emitChunk([0.2])
        await settle()

        #expect(rig.recorder.stopCount == 1)
        await rig.transcriber.resumeDecode()
        await settle(80)

        let requests = await rig.transcriber.requests
        #expect(requests.map(\.audio.count) == [sixtySeconds.count, sixtySeconds.count])
        #expect(rig.panel.shownText == "first second")
        #expect(rig.panel.incompleteWarnings == ["Incomplete transcription"])
        await rig.controller.shutdown()
    }

    // MARK: - Guards

    @Test("The hotkey is ignored while the previous session is still processing")
    func ignoresHotkeyWhileProcessing() async {
        let rig = makeRig(texts: ["текст"], delay: 0.3)

        rig.controller.toggle(now: Date())
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: Date().addingTimeInterval(1))
        #expect(rig.controller.isProcessing == true)

        rig.controller.toggle(now: Date().addingTimeInterval(2))
        #expect(rig.controller.isRecording == false)
        #expect(rig.controller.sessionId == 1)
        await settle(40)
    }

    @Test("File transcription blocks the recording hotkey")
    func fileJobBlocksHotkey() async {
        let transcriber = SuspendingFileTranscriber()
        let recorder = FakeRecorder()
        let controller = SessionController(
            config: Self.makeConfig(),
            transcriber: transcriber,
            recorder: recorder,
            panel: FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )
        let job = Task {
            await controller.transcribeFile(url: URL(fileURLWithPath: "activity.wav"))
        }
        await transcriber.waitUntilStarted()

        controller.toggle(now: Date())
        await settle()

        #expect(recorder.startCount == 0)
        #expect(controller.sessionId == 0)
        await transcriber.finish()
        _ = await job.value
        await controller.shutdown()
    }

    @Test("Injection blocks a new recording")
    func injectingBlocksHotkey() async {
        let rig = makeRig(texts: ["first"])
        await runSession(rig)

        rig.panel.userConfirms()
        rig.controller.toggle(now: Date().addingTimeInterval(2))
        await settle()

        #expect(rig.recorder.startCount == 1)
        #expect(rig.controller.sessionId == 1)
        await rig.controller.shutdown()
    }

    @Test("Only one file transcription owns the session activity")
    func secondFileRequestIsRejected() async {
        let transcriber = SuspendingFileTranscriber()
        let controller = SessionController(
            config: Self.makeConfig(),
            transcriber: transcriber,
            recorder: FakeRecorder(),
            panel: FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )
        let first = Task {
            await controller.transcribeFile(url: URL(fileURLWithPath: "first.wav"))
        }
        await transcriber.waitUntilStarted()

        let second = await controller.transcribeFile(url: URL(fileURLWithPath: "second.wav"))

        guard case let .failed(failure) = second.status else {
            Issue.record("Expected the overlapping file request to be rejected")
            await transcriber.finish()
            _ = await first.value
            return
        }
        #expect(failure.kind == .unavailable)
        #expect(await transcriber.fileRequestCount == 1)
        await transcriber.finish()
        _ = await first.value
        await controller.shutdown()
    }

    @Test("An open popup rejects file transcription without losing its draft")
    func popupBlocksFileRequest() async {
        let rig = makeRig(texts: ["draft"])
        await runSession(rig)

        let result = await rig.controller.transcribeFile(
            url: URL(fileURLWithPath: "blocked.wav")
        )

        guard case let .failed(failure) = result.status else {
            Issue.record("Expected file transcription to be rejected while the popup is open")
            return
        }
        #expect(failure.kind == .unavailable)
        #expect(rig.panel.isShowingInteractive)
        #expect(rig.panel.shownText == "draft")
        await rig.controller.shutdown()
    }

    @Test("Runtime mutation reservation excludes recording and file work")
    func runtimeMutationExcludesSessionActivities() async {
        let rig = makeRig()

        #expect(rig.controller.beginRuntimeMutation())
        #expect(!rig.controller.beginRuntimeMutation())
        #expect(!rig.controller.isRuntimeIdle)
        rig.controller.toggle(now: Date())
        let fileResult = await rig.controller.transcribeFile(
            url: URL(fileURLWithPath: "blocked.wav")
        )

        #expect(rig.recorder.startCount == 0)
        #expect(rig.controller.sessionId == 0)
        guard case let .failed(failure) = fileResult.status else {
            Issue.record("Expected the runtime reservation to reject file work")
            return
        }
        #expect(failure.kind == .unavailable)

        rig.controller.endRuntimeMutation()
        rig.controller.endRuntimeMutation()
        #expect(rig.controller.isRuntimeIdle)
        rig.controller.toggle(now: Date().addingTimeInterval(1))
        await settle()
        #expect(rig.recorder.startCount == 1)
        await rig.controller.shutdown()
    }

    @Test("File transcription publishes a processing state until completion")
    func fileJobPublishesProcessingState() async {
        let transcriber = SuspendingFileTranscriber()
        var states: [SessionState] = []
        let controller = SessionController(
            config: Self.makeConfig(),
            transcriber: transcriber,
            recorder: FakeRecorder(),
            panel: FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            onStateChanged: { states.append($0) }
        )
        let job = Task {
            await controller.transcribeFile(url: URL(fileURLWithPath: "state.wav"))
        }
        await transcriber.waitUntilStarted()

        #expect(states.contains(.fileProcessing))
        #expect(!controller.isRuntimeIdle)
        await transcriber.finish()
        _ = await job.value
        #expect(states.last == .idle)
        await controller.shutdown()
    }

    @Test("Cancelling during file refinement reaches the editor and preserves decoded text")
    func cancellingFileRefinementPreservesDecodedText() async {
        let transcriber = SuspendingFileTranscriber()
        let editor = SuspendingFileAiEditor()
        var config = Self.makeConfig()
        config.raw["ai_editor_enabled"] = .bool(true)
        let controller = SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )
        let job = Task {
            await controller.transcribeFile(
                url: URL(fileURLWithPath: "refining.wav"),
                refine: true
            )
        }
        await transcriber.waitUntilStarted()
        await transcriber.finish()
        await editor.waitUntilStarted()

        job.cancel()
        let result = await job.value

        #expect(result.status == .cancelled)
        #expect(result.text == "file text")
        #expect(await editor.cancellationCount == 1)
        #expect(controller.state == .idle)
        await controller.shutdown()
    }

    @Test("Provider completion stays intermediate until optional file refinement finishes")
    func fileProgressCompletesAfterRefinement() async {
        let transcriber = SuspendingFileTranscriber()
        let editor = FakeAiEditor()
        let progress = FileProgressRecorder()
        var config = Self.makeConfig()
        config.raw["ai_editor_enabled"] = .bool(true)
        let controller = SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )
        let job = Task {
            await controller.transcribeFile(
                url: URL(fileURLWithPath: "progress.wav"),
                refine: true
            ) { update in
                Task { await progress.append(update) }
            }
        }
        await transcriber.waitUntilStarted()

        await transcriber.emitProgress(
            .init(stage: .completed, completedUnits: 1, totalUnits: 1),
            call: 0
        )
        await settle()
        #expect(await progress.updates.allSatisfy { $0.stage != .completed })

        await transcriber.finish()
        _ = await job.value
        await progress.waitForCount(2)
        let stages = await progress.updates.map(\.stage)
        #expect(stages == [.refining, .completed])
        await controller.shutdown()
    }

    @Test("A file job keeps its starting prompt and languages across config changes")
    func fileJobUsesConfigurationSnapshot() async {
        let transcriber = SuspendingFileTranscriber()
        let editor = FakeAiEditor()
        var initial = Self.makeConfig(primary: "ru", additional: ["en"])
        initial.raw["initial_prompt"] = .string("OLD FILE PROMPT")
        initial.raw["ai_editor_enabled"] = .bool(true)
        let controller = SessionController(
            config: initial,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost()
        )
        let job = Task {
            await controller.transcribeFile(
                url: URL(fileURLWithPath: "snapshot.wav"),
                refine: true
            )
        }
        await transcriber.waitUntilStarted()

        var updated = Self.makeConfig(primary: "de", additional: ["fr"])
        updated.raw["initial_prompt"] = .string("NEW FILE PROMPT")
        updated.raw["ai_editor_enabled"] = .bool(true)
        controller.updateConfig(updated)
        await transcriber.finish()
        _ = await job.value

        let request = await transcriber.fileRequests.first
        #expect(request?.initialPrompt == "OLD FILE PROMPT")
        #expect(request?.allowedLanguages == ["ru", "en"])
        #expect(editor.lastLanguages == ["ru", "en"])

        let nextJob = Task {
            await controller.transcribeFile(
                url: URL(fileURLWithPath: "next-snapshot.wav"),
                refine: true
            )
        }
        while await transcriber.fileRequestCount < 2 { await Task.yield() }
        await transcriber.finish()
        _ = await nextJob.value
        let nextRequest = await transcriber.fileRequests.last
        #expect(nextRequest?.initialPrompt == "NEW FILE PROMPT")
        #expect(nextRequest?.allowedLanguages == ["de", "fr"])
        #expect(editor.lastLanguages == ["de", "fr"])
        await controller.shutdown()
    }

    @Test("Shutdown is terminal for new hotkey and file work")
    func shutdownBlocksNewActivities() async {
        let rig = makeRig()

        await rig.controller.shutdown()
        rig.controller.toggle(now: Date())
        let fileResult = await rig.controller.transcribeFile(
            url: URL(fileURLWithPath: "after-shutdown.wav")
        )

        #expect(rig.controller.isShuttingDown)
        #expect(rig.recorder.startCount == 0)
        guard case let .failed(failure) = fileResult.status else {
            Issue.record("Expected file transcription to be rejected after shutdown")
            return
        }
        #expect(failure.kind == .unavailable)
    }

    @Test("Shutdown suppresses a late editor completion")
    func shutdownCannotReopenPopup() async {
        let editor = FakeAiEditor()
        editor.refineDelay = 0.5
        var config = Self.makeConfig()
        config.raw["ai_editor_enabled"] = .bool(true)
        let rig = makeRig(texts: ["first"], config: config, aiEditor: editor)
        let base = Date()

        rig.controller.toggle(now: base)
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(1))
        while !editor.didCallRefine { await Task.yield() }

        await rig.controller.shutdown()
        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(!rig.panel.isShowingInteractive)
        #expect(rig.controller.state == .idle)
    }

    @Test("Shutdown reports an injection that ignores cancellation and can be retried")
    func shutdownTimesOutForStuckDelivery() async {
        let rig = makeRig(shutdownTimeout: 0.05)
        rig.delivery.suspend = true
        await runSession(rig)
        rig.panel.userConfirms("preserve me")
        while rig.delivery.delivered.isEmpty { await Task.yield() }

        let first = await rig.controller.shutdown()

        #expect(!first.succeeded)
        #expect(first.pendingActivities.contains(.injection))
        #expect(rig.controller.popupDraft != nil)
        #expect(!rig.panel.isShowingInteractive)
        #expect(rig.controller.state == .idle)

        rig.delivery.resume()
        await settle()
        let second = await rig.controller.shutdown()
        #expect(second.succeeded)
    }

    @Test("Concurrent shutdown calls share one terminal drain")
    func duplicateShutdownIsIdempotent() async {
        let rig = makeRig(shutdownTimeout: 1)
        rig.delivery.suspend = true
        await runSession(rig)
        rig.panel.userConfirms("preserve me")
        while rig.delivery.delivered.isEmpty { await Task.yield() }

        let first = Task { await rig.controller.shutdown() }
        let second = Task { await rig.controller.shutdown() }
        await settle()
        rig.delivery.resume()

        #expect(await first.value.succeeded)
        #expect(await second.value.succeeded)
        #expect(rig.recorder.stopCount == 2) // session stop plus one shutdown stop
    }

    @Test("Shutdown waits for an acknowledged confirmation write")
    func shutdownDrainsConfirmation() async {
        let coordinator = FakeDictionaryCoordinator(config: Self.makeConfig())
        coordinator.suspendConfirmation = true
        let rig = makeRig(
            dictionaryCoordinator: coordinator,
            shutdownTimeout: 1
        )
        await runSession(rig)
        rig.panel.userConfirms("saved before exit")
        while !coordinator.confirmationStarted { await Task.yield() }
        let result = ShutdownResultRecorder()

        let shutdown = Task {
            let outcome = await rig.controller.shutdown()
            result.record(outcome)
            return outcome
        }
        await settle()

        #expect(result.value == nil)
        coordinator.finishConfirmation()
        #expect(await shutdown.value.succeeded)
        #expect(coordinator.confirmations.count == 1)
        #expect(coordinator.confirmations.first?.finalText == "saved before exit")
    }

    @Test("A queued final chunk cannot publish after shutdown")
    func queuedFinalCannotPublishAfterShutdown() async {
        let rig = makeRig(texts: ["first", "late final"], shutdownTimeout: 1)
        let base = Date()
        rig.controller.toggle(now: base)
        await settle()
        await rig.transcriber.suspendOneDecode()
        rig.recorder.scriptedChunks = [audio]
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(1))
        await rig.transcriber.waitUntilRequestCount(1)

        let shutdown = Task { await rig.controller.shutdown() }
        await settle()
        await rig.transcriber.resumeDecode()
        #expect(await shutdown.value.succeeded)
        await settle()

        #expect(rig.panel.interactiveTexts.isEmpty)
        #expect(!rig.panel.isShowingInteractive)
        #expect(rig.controller.state == .idle)
    }

    @Test("A recorder that starts after cancellation is stopped before shutdown succeeds")
    func lateRecorderStartIsDrained() async {
        let rig = makeRig(shutdownTimeout: 1)
        rig.recorder.suspendStart = true
        rig.recorder.ignoreStartCancellation = true
        rig.controller.toggle(now: Date())
        await settle()

        let shutdown = Task { await rig.controller.shutdown() }
        await settle()
        rig.recorder.resumeStart()

        #expect(await shutdown.value.succeeded)
        #expect(!rig.recorder.isRecording)
        #expect(rig.recorder.stopCount == 2)
        #expect(rig.controller.state == .idle)
    }

    @Test("A file backend that ignores cancellation is visible in shutdown outcome")
    func stuckFileJobBlocksShutdownAcknowledgement() async {
        let transcriber = SuspendingFileTranscriber()
        let controller = SessionController(
            config: Self.makeConfig(),
            transcriber: transcriber,
            recorder: FakeRecorder(),
            panel: FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            shutdownTimeout: 0.05
        )
        let fileJob = Task {
            await controller.transcribeFile(url: URL(fileURLWithPath: "stuck.wav"))
        }
        await transcriber.waitUntilStarted()

        let first = await controller.shutdown()

        #expect(!first.succeeded)
        #expect(first.pendingActivities.contains(.file))
        await transcriber.finish()
        #expect(await fileJob.value.status == .cancelled)
        #expect(await controller.shutdown().succeeded)
    }

    @Test("File cancellation does not abort an unrelated transcription runtime")
    func idleFileCancellationDoesNotAbortRuntime() async {
        let rig = makeRig()

        rig.controller.cancelFileTranscription()

        #expect(await rig.transcriber.abortCount == 0)
    }

    @Test("A transcriber reload blocks a new recording")
    func reloadBlocksHotkey() async {
        let rig = makeRig(texts: Array(repeating: "text", count: 20))
        await rig.transcriber.setSuspendReload(true)
        let base = Date()
        for index in 0..<20 {
            rig.controller.toggle(now: base.addingTimeInterval(Double(index) * 3))
            await settle(4)
            rig.recorder.finalChunk = audio
            rig.controller.toggle(now: base.addingTimeInterval(Double(index) * 3 + 1))
            await settle(4)
            rig.panel.userCancels()
        }
        await rig.transcriber.waitUntilReloadStarted()
        let startsBeforeHotkey = rig.recorder.startCount

        rig.controller.toggle(now: base.addingTimeInterval(61))
        await settle()

        #expect(rig.recorder.startCount == startsBeforeHotkey)
        #expect(rig.controller.sessionId == 20)
        await rig.transcriber.finishReload()
        await settle()
        await rig.controller.shutdown()
    }

    @Test("Presses inside the debounce window are dropped")
    func debounces() async {
        let rig = makeRig()
        let now = Date()

        rig.controller.toggle(now: now)
        rig.controller.toggle(now: now.addingTimeInterval(0.1))  // too soon to stop

        #expect(rig.controller.isRecording == true)
        #expect(rig.controller.sessionId == 1)
        await settle()
    }

    @Test("After a fatal recorder error the hotkey stops responding")
    func blocksAfterFatalError() async {
        let rig = makeRig()
        rig.controller.handleRecorderFatalError()

        rig.controller.toggle(now: Date())

        #expect(rig.controller.isRecording == false)
        #expect(rig.controller.sessionId == 0)
    }

    @Test("A recorder that fails to start does not leave the session stuck")
    func recoversFromStartFailure() async {
        let rig = makeRig()
        rig.recorder.startError = RecorderErrorStub.failed
        rig.controller.toggle(now: Date())
        await settle()

        #expect(rig.controller.isRecording == false)
        #expect(rig.panel.statuses.contains("Recording error"))
    }

    @Test("Stopping while recorder startup is suspended cannot start the stale engine")
    func stopBeforeRecorderStartupCompletes() async {
        let rig = makeRig(texts: [])
        rig.recorder.suspendStart = true
        let now = Date()

        rig.controller.toggle(now: now)
        await settle(2)
        #expect(rig.controller.isRecording == true)
        if case .starting(sessionID: 1, targetPID: _, appendMode: false) = rig.controller.state {
            // Expected explicit startup state.
        } else {
            Issue.record("Expected session 1 to remain in starting state")
        }

        rig.controller.toggle(now: now.addingTimeInterval(1))
        rig.recorder.resumeStart()
        await settle(30)

        #expect(rig.recorder.isRecording == false)
        #expect(rig.controller.isRecording == false)
        #expect(rig.controller.isProcessing == false)
        #expect(rig.controller.state == .idle)
        #expect(rig.panel.interactiveTexts.isEmpty)
        #expect(rig.controller.popupDraft == nil)
        #expect(rig.controller.completedSessions == 1)
    }

    @Test("Thirty rapid toggles settle without overlapping session generations")
    func rapidToggleBurst() async {
        let rig = makeRig(texts: [])
        let start = Date()

        for index in 0..<30 {
            rig.controller.toggle(now: start.addingTimeInterval(Double(index) * 0.31))
        }
        await settle(40)

        #expect(rig.controller.sessionId == 1)
        #expect(rig.controller.completedSessions == 1)
        #expect(rig.controller.isRecording == false)
        #expect(rig.controller.isProcessing == false)
        #expect(rig.recorder.isRecording == false)
    }

    @Test("Duplicate final and popup callbacks complete the session once")
    func duplicateCallbacksAreIdempotent() async {
        let rig = makeRig(texts: ["один текст"])
        rig.recorder.duplicateFinalCallback = true
        await runSession(rig)

        rig.panel.userConfirms()
        rig.panel.userCancels()
        await settle(200)

        #expect(rig.controller.completedSessions == 1)
        #expect(await rig.transcriber.requestCount == 1)
        #expect(rig.delivery.delivered.count == 1)
    }

    @Test("Hotkey start never queues synthetic prewarm work")
    func hotkeyDoesNotPrewarm() async {
        let rig = makeRig()
        await runSession(rig)

        #expect(await rig.transcriber.preWarmCount == 0)
        #expect(await rig.transcriber.warmupCount == 0)
    }

    @Test("Hotkey cancels an in-flight synthetic prewarm before recording")
    func hotkeyCancelsInFlightPrewarm() async {
        let rig = makeRig()
        await rig.transcriber.setSuspendPreWarm(true)
        let warmup = Task { await rig.controller.warmupIfIdle(full: false) }
        await rig.transcriber.waitUntilPreWarmStarted()

        rig.controller.toggle(now: Date())
        await settle(20)

        let cancelCount = await rig.transcriber.preWarmCancelledCount
        let abortCount = await rig.transcriber.abortCount
        await rig.transcriber.setSuspendPreWarm(false)
        let accepted = await warmup.value

        #expect(cancelCount == 1)
        #expect(abortCount == 1)
        #expect(accepted == false)
        #expect(rig.recorder.isRecording)
        #expect(rig.controller.isRecording)
    }

    @Test("Dataset metadata uses the runtime captured at session start")
    func datasetUsesFactualRuntimeDescriptor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-runtime-metadata-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("dataset.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = RuntimeDescriptor(
            transcriber: TranscriberDescriptor(
                backend: "openai", modelID: "gpt-4o-transcribe", kind: .cloud
            ),
            aiEditor: AiEditorDescriptor(
                backend: "gemini", modelID: "gemini-2.5-flash-lite", kind: .cloud
            )
        )
        let rig = makeRig(
            datasetLogger: DatasetLogger(fileURL: file),
            runtimeDescriptorProvider: { descriptor }
        )

        await runSession(rig)
        rig.panel.userConfirms()
        await settle(10)

        let line = try String(contentsOf: file, encoding: .utf8)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(object["stt_backend"] as? String == "openai")
        #expect(object["stt_model"] as? String == "gpt-4o-transcribe")
        #expect(object["ai_model"] as? String == "gemini-2.5-flash-lite")
    }

    @Test("Dataset records factual AI timeout without claiming edited text")
    func datasetUsesFactualAiStatus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-ai-status-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("dataset.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Self.makeConfig()
        config.raw["ai_editor_enabled"] = .bool(true)
        let editor = FakeAiEditor()
        editor.refineStatus = .timeout
        editor.refinedText = "must not be recorded as edited"
        let descriptor = RuntimeDescriptor(
            transcriber: .init(backend: "local", modelID: "whisper-test", kind: .local),
            aiEditor: .init(backend: "local", modelID: "qwen-test", kind: .local)
        )
        let rig = makeRig(
            config: config,
            aiEditor: editor,
            datasetLogger: DatasetLogger(fileURL: file),
            runtimeDescriptorProvider: { descriptor }
        )

        await runSession(rig)
        rig.panel.userConfirms()
        await settle(10)

        let line = try String(contentsOf: file, encoding: .utf8)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(object["ai_status"] as? String == "timeout")
        #expect(object["ai_edited"] is NSNull)
        #expect(object["ai_model"] as? String == "qwen-test")
    }

    @Test("Silence produces no popup")
    func noSpeechNoPopup() async {
        let rig = makeRig(texts: [])
        await runSession(rig)

        #expect(rig.panel.interactiveTexts.isEmpty)
        #expect(rig.panel.statuses.contains("No speech detected"))
        #expect(rig.controller.isProcessing == false)
    }

    @Test("A typed provider failure is not presented as no speech")
    func providerFailureIsActionable() async {
        let rig = makeRig(
            texts: [],
            results: [TranscriptionResult.failed(
                .init(kind: .unauthorized, message: "Cloud key was rejected")
            )]
        )
        await runSession(rig)

        #expect(rig.panel.interactiveTexts.isEmpty)
        #expect(rig.panel.statuses.contains("Cloud key was rejected"))
        #expect(!rig.panel.statuses.contains("No speech detected"))
    }

    @Test("A decode timeout has a distinct user-visible status")
    func timeoutIsDistinctFromNoSpeech() async {
        let rig = makeRig(texts: [], results: [.init(text: "", outcome: .timedOut)])
        await runSession(rig)

        #expect(rig.panel.interactiveTexts.isEmpty)
        #expect(rig.panel.statuses.contains("Speech recognition timed out"))
        #expect(!rig.panel.statuses.contains("No speech detected"))
    }

    @Test("Audio from a finished session never reaches the next one")
    func dropsStaleSessionAudio() async {
        let rig = makeRig(texts: ["из первой сессии", "из второй сессии"])
        await runSession(rig)
        rig.panel.userConfirms()
        await settle(200)

        rig.controller.toggle(now: Date().addingTimeInterval(2))
        await settle()
        // The previous session's audio callback fires late.
        rig.recorder.emitStaleChunk(audio)
        await settle()

        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: Date().addingTimeInterval(3))
        await settle()

        #expect(rig.controller.sessionId == 2)
        #expect(rig.panel.interactiveTexts.count == 2)
        if rig.panel.interactiveTexts.count == 2 {
            #expect(rig.panel.interactiveTexts[1] == "из второй сессии")
        }
    }

    // MARK: - Language selection

    @Test("Allowed languages are primary first, then additional")
    func allowedLanguages() {
        let rig = makeRig(config: Self.makeConfig(primary: "ru", additional: ["en", "ru", "de"]))
        #expect(rig.controller.allowedLanguages() == ["ru", "en", "de"])
    }

    @Test("Auto-detect sends no language hint at all")
    func autoDetectSendsNoLanguages() {
        let rig = makeRig(config: Self.makeConfig(autoDetect: true))
        #expect(rig.controller.allowedLanguages().isEmpty)
    }

    @Test("A recording keeps its starting prompt and languages for every chunk")
    func recordingUsesConfigurationSnapshot() async {
        var initial = Self.makeConfig(primary: "ru", additional: ["en"])
        initial.raw["initial_prompt"] = .string("OLD RECORDING PROMPT")
        initial.raw["ai_editor_enabled"] = .bool(true)
        let editor = FakeAiEditor()
        let rig = makeRig(
            texts: ["first", "second", "third"],
            config: initial,
            aiEditor: editor
        )
        await rig.transcriber.suspendOneDecode()
        let base = Date()
        rig.controller.toggle(now: base)
        await settle()
        rig.recorder.emitChunk(audio)
        await rig.transcriber.waitUntilRequestCount(1)

        var updated = Self.makeConfig(primary: "de", additional: ["fr"])
        updated.raw["initial_prompt"] = .string("NEW RECORDING PROMPT")
        updated.raw["ai_editor_enabled"] = .bool(true)
        rig.controller.updateConfig(updated)
        await rig.transcriber.resumeDecode()
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(1))
        while !rig.panel.isShowingInteractive { await Task.yield() }

        let requests = await rig.transcriber.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.allowedLanguages == ["ru", "en"] })
        #expect(requests.allSatisfy { $0.initialPrompt?.contains("OLD RECORDING PROMPT") == true })
        #expect(requests.allSatisfy { $0.initialPrompt?.contains("NEW RECORDING PROMPT") == false })
        #expect(editor.lastLanguages == ["ru", "en"])

        rig.panel.userCancels()
        await settle()
        rig.controller.toggle(now: base.addingTimeInterval(2))
        await settle()
        rig.recorder.finalChunk = audio
        rig.controller.toggle(now: base.addingTimeInterval(3))
        while await rig.transcriber.requestCount < 3 { await Task.yield() }
        let nextRequest = await rig.transcriber.requests.last
        #expect(nextRequest?.allowedLanguages == ["de", "fr"])
        #expect(nextRequest?.initialPrompt?.contains("NEW RECORDING PROMPT") == true)
        await rig.controller.shutdown()
    }

    // MARK: - Dictionary

    @Test("⌘D adds the term and hands the updated config back")
    func addsTermToDictionary() async {
        var saved: Config?
        let rig = makeRig(onConfigChanged: { saved = $0 })
        await runSession(rig)

        let result = rig.panel.userAddsTerm("Whisper")

        #expect(result == .added(message: "„Whisper“ → English"))
        #expect(saved?.raw["user_terms"]?.objectValue?["en"]?.arrayValue?.count == 1)
        // The prompt is rebuilt so the next chunk already sees the term.
        #expect(saved?.initialPrompt.contains("Whisper") == true)
    }

    @Test("A term already in the dictionary is reported, not duplicated")
    func rejectsDuplicateTerm() async {
        var saved: Config?
        let rig = makeRig(onConfigChanged: { saved = $0 })
        await runSession(rig)

        _ = rig.panel.userAddsTerm("Whisper")
        let second = rig.panel.userAddsTerm("whisper")

        #expect(second == .alreadyExists)
        #expect(saved?.raw["user_terms"]?.objectValue?["en"]?.arrayValue?.count == 1)
    }

    // MARK: - Model reload

    @Test("The model is reloaded every 20 completed sessions")
    func reloadsPeriodically() async {
        let rig = makeRig(texts: Array(repeating: "текст", count: 20))

        for i in 0..<20 {
            rig.controller.toggle(now: Date().addingTimeInterval(Double(i) * 2))
            await settle(4)
            rig.recorder.finalChunk = audio
            rig.controller.toggle(now: Date().addingTimeInterval(Double(i) * 2 + 1))
            await settle(4)
            rig.panel.userCancels()
        }
        await settle()

        #expect(rig.controller.completedSessions == 20)
        #expect(await rig.transcriber.reloadCount == 1)
    }
    @Test("AI Editor refines text before showing interactive popup")
    func testFinalizeWithAiEditor() async {
        let aiEditor = FakeAiEditor()
        aiEditor.refinedText = "super refined text"
        
        // Ensure ai_editor_enabled is true in config
        var config = Self.makeConfig()
        config.raw["ai_editor_enabled"] = .bool(true)
        
        let rig = makeRig(texts: ["raw STT"], config: config, aiEditor: aiEditor)
        
        let now = Date()
        rig.controller.toggle(now: now)
        await settle()
        
        rig.recorder.finalChunk = [Float](repeating: 0, count: 16000)
        
        rig.controller.toggle(now: now.addingTimeInterval(2.0))
        
        while !rig.panel.isShowingInteractive { await Task.yield() }
        
        #expect(aiEditor.didCallRefine)
        #expect(aiEditor.lastInputText == "raw STT")
        
        // Wait, the panel should show the refined text
        #expect(rig.panel.shownText == "super refined text")
    }

    @Test("Replacement policy mirrors local and cloud editor hint behavior")
    func replacementPolicy() {
        for status in [
            RefineStatus.disabled, .skipped, .timeout, .error, .memoryPressure,
        ] {
            #expect(SessionController.shouldApplyDirectReplacements(after: status, hintsInPrompt: false))
            #expect(SessionController.shouldApplyDirectReplacements(after: status, hintsInPrompt: true))
        }
        #expect(SessionController.shouldApplyDirectReplacements(after: nil, hintsInPrompt: false))
        #expect(SessionController.shouldApplyDirectReplacements(after: .unchanged, hintsInPrompt: false))
        #expect(!SessionController.shouldApplyDirectReplacements(after: .unchanged, hintsInPrompt: true))
        #expect(!SessionController.shouldApplyDirectReplacements(after: .ok, hintsInPrompt: false))
    }

    @Test("Local unchanged output receives mechanical replacements")
    func localUnchangedAppliesReplacement() async {
        var config = Self.makeConfig(primary: "en", additional: [])
        config.raw["ai_editor_enabled"] = .bool(true)
        var replacement = JSONObject()
        replacement["from"] = .string("click and speak")
        replacement["to"] = .string("Click-n-speak")
        config.raw["manual_replacements"] = .array([.object(replacement)])
        let source = "click and speak keeps the original transcript when the local editor returns unchanged"
        let editor = FakeAiEditor()
        editor.refinedText = source
        editor.refineStatus = .unchanged
        let runtime = RuntimeDescriptor(
            transcriber: .init(backend: "local", modelID: "whisper-test", kind: .local),
            aiEditor: .init(backend: "local", modelID: "qwen-test", kind: .local)
        )
        let rig = makeRig(
            texts: [source],
            config: config,
            aiEditor: editor,
            runtimeDescriptorProvider: { runtime }
        )

        await runSession(rig)

        #expect(rig.panel.shownText.hasPrefix("Click-n-speak keeps"))
    }

    @Test("Cloud unchanged output avoids applying the same hints twice")
    func cloudUnchangedSkipsReplacement() async {
        var config = Self.makeConfig(primary: "en", additional: [])
        config.raw["ai_editor_enabled"] = .bool(true)
        var replacement = JSONObject()
        replacement["from"] = .string("click and speak")
        replacement["to"] = .string("Click-n-speak")
        config.raw["manual_replacements"] = .array([.object(replacement)])
        let source = "click and speak keeps the cloud editor response unchanged without a second pass"
        let editor = FakeAiEditor()
        editor.refinedText = source
        editor.refineStatus = .unchanged
        let runtime = RuntimeDescriptor(
            transcriber: .init(backend: "local", modelID: "whisper-test", kind: .local),
            aiEditor: .init(backend: "gemini", modelID: "gemini-test", kind: .cloud)
        )
        let rig = makeRig(
            texts: [source],
            config: config,
            aiEditor: editor,
            runtimeDescriptorProvider: { runtime }
        )

        await runSession(rig)

        #expect(rig.panel.shownText == source)
    }

    @Test("Unapproved automatic pair never changes fallback text")
    func unapprovedAutomaticPairIsHintOnly() async throws {
        let source = "Cogni stores memory"
        var config = Self.makeConfig(primary: "en", additional: [])
        config.raw["replacement_policy_initialized"] = .bool(true)
        let coordinator = FakeDictionaryCoordinator(config: config)
        try writeReplacementIndex(
            from: "Cogni",
            to: "Cognee",
            count: 5,
            indexURL: coordinator.correctionsURL
        )
        let rig = makeRig(
            texts: [source],
            config: config,
            dictionaryCoordinator: coordinator
        )

        await runSession(rig)

        #expect(rig.panel.shownText == source)
    }

    @Test("Approved automatic pair changes eligible fallback text")
    func approvedAutomaticPairApplies() async throws {
        let source = "Cogni stores memory"
        var config = Self.makeConfig(primary: "en", additional: [])
        config.raw["replacement_policy_initialized"] = .bool(true)
        config.raw["approved_auto_replacements"] = .array([
            replacementValue(from: "Cogni", to: "Cognee", timestampKey: "approved_at"),
        ])
        let coordinator = FakeDictionaryCoordinator(config: config)
        try writeReplacementIndex(
            from: "Cogni",
            to: "Cognee",
            count: 5,
            indexURL: coordinator.correctionsURL
        )
        let rig = makeRig(
            texts: [source],
            config: config,
            dictionaryCoordinator: coordinator
        )

        await runSession(rig)

        #expect(rig.panel.shownText == "Cognee stores memory")
    }

    @Test("Count-two pair reaches cloud editor but not direct fallback")
    func countTwoPairIsCloudHintOnly() async throws {
        let source = "Cogni stores memory"
        var config = Self.makeConfig(primary: "en", additional: [])
        config.raw["replacement_policy_initialized"] = .bool(true)
        config.raw["ai_editor_enabled"] = .bool(true)
        let coordinator = FakeDictionaryCoordinator(config: config)
        try writeReplacementIndex(
            from: "Cogni",
            to: "Cognee",
            count: 2,
            indexURL: coordinator.correctionsURL
        )
        let editor = FakeAiEditor()
        editor.refinedText = source
        editor.refineStatus = .error
        let runtime = RuntimeDescriptor(
            transcriber: .init(backend: "local", modelID: "whisper-test", kind: .local),
            aiEditor: .init(backend: "gemini", modelID: "gemini-test", kind: .cloud)
        )
        let rig = makeRig(
            texts: [source],
            config: config,
            aiEditor: editor,
            dictionaryCoordinator: coordinator,
            runtimeDescriptorProvider: { runtime }
        )

        await runSession(rig)

        #expect(editor.lastMisrecognitions?.contains { $0.0 == "Cogni" && $0.1 == "Cognee" } == true)
        #expect(rig.panel.shownText == source)
    }

    private func replacementValue(from: String, to: String, timestampKey: String) -> JSONValue {
        var object = JSONObject()
        object["from"] = .string(from)
        object["to"] = .string(to)
        object[timestampKey] = .string(ISOTimestamp.now())
        return .object(object)
    }

    private func writeReplacementIndex(from: String, to: String, count: Int, indexURL url: URL) throws {
        var index = CorrectionIndex.defaultIndex()
        index.processedRows = count
        index.replacementPairs["latin"] = [
            ReplacementPair(
                from: from,
                to: to,
                count: count,
                lastSeen: ISOTimestamp.now(),
                lastSeenRow: count
            ),
        ]
        try CorrectionAnalyzer.writeIndex(index, to: url)
    }
}

enum RecorderErrorStub: Error { case failed }
