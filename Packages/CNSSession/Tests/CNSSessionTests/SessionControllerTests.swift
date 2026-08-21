import CNSCore
import CNSUI
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
    }

    private func makeRig(
        texts: [String] = ["распознанный текст"],
        delay: TimeInterval = 0,
        config: Config? = nil,
        onConfigChanged: @escaping (Config) -> Void = { _ in }
    ) -> Rig {
        let panel = FakePanel()
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(texts: texts, delay: delay)
        let delivery = FakeDelivery()
        let frontmost = FakeFrontmost()
        let controller = SessionController(
            config: config ?? Self.makeConfig(),
            transcriber: transcriber,
            recorder: recorder,
            panel: panel,
            delivery: delivery,
            frontmost: frontmost,
            onConfigChanged: onConfigChanged
        )
        return Rig(
            controller: controller, panel: panel, recorder: recorder,
            transcriber: transcriber, delivery: delivery, frontmost: frontmost
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

    @Test("Silence produces no popup")
    func noSpeechNoPopup() async {
        let rig = makeRig(texts: [])
        await runSession(rig)

        #expect(rig.panel.interactiveTexts.isEmpty)
        #expect(rig.panel.statuses.contains("No speech detected"))
        #expect(rig.controller.isProcessing == false)
    }

    @Test("Audio from a finished session never reaches the next one")
    func dropsStaleSessionAudio() async {
        let rig = makeRig(texts: ["из первой сессии", "из второй сессии"])
        await runSession(rig)
        rig.panel.userConfirms()
        await settle()

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
        #expect(rig.panel.interactiveTexts[1] == "из второй сессии")
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
}

enum RecorderErrorStub: Error { case failed }
