import CNSCore
import Foundation
import Testing
@testable import CNSSession

/// A decode that runs long must not silently unlock the session, and must not
/// block it forever either: the soft timeout only changes what the HUD says, the
/// hard deadline aborts the decode (§6 invariant 6).
@MainActor
@Suite("Overdue worker watchdog")
struct OverdueWatchdogTests {
    private let audio = [Float](repeating: 0.2, count: 16000)

    private func makeController(
        transcriber: FakeTranscriber,
        panel: FakePanel,
        recorder: FakeRecorder,
        soft: TimeInterval,
        hard: TimeInterval
    ) -> SessionController {
        var obj = JSONObject()
        obj["schema_version"] = .int(9)
        obj["primary_language"] = .string("ru")
        return SessionController(
            config: Config(raw: obj),
            transcriber: transcriber,
            recorder: recorder,
            panel: panel,
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            workerSoftTimeout: soft,
            workerHardTimeout: hard
        )
    }

    private func settle(_ rounds: Int) async {
        for _ in 0..<rounds {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("A slow decode keeps the session blocked and switches the HUD message")
    func softTimeoutKeepsSessionBlocked() async {
        let panel = FakePanel()
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(texts: ["поздний текст"], delay: 0.5)
        let controller = makeController(
            transcriber: transcriber, panel: panel, recorder: recorder, soft: 0.05, hard: 5
        )

        controller.toggle(now: Date())
        await settle(4)
        recorder.finalChunk = audio
        controller.toggle(now: Date().addingTimeInterval(1))
        await settle(20)

        #expect(controller.workerOverdue == true)
        #expect(controller.isProcessing == true)  // never cleared by the soft timeout
        #expect(panel.statuses.last == "Still working…")

        await settle(120)
        #expect(controller.isProcessing == false)
        #expect(panel.interactiveTexts == ["поздний текст"])
    }

    @Test("Past the hard deadline the decode is aborted and the model reloaded")
    func hardTimeoutAbortsDecode() async {
        let panel = FakePanel()
        let recorder = FakeRecorder()
        // Far longer than the hard deadline: only an abort ends this decode.
        let transcriber = FakeTranscriber(texts: ["никогда"], delay: 30)
        let controller = makeController(
            transcriber: transcriber, panel: panel, recorder: recorder, soft: 0.05, hard: 0.2
        )

        controller.toggle(now: Date())
        await settle(4)
        recorder.finalChunk = audio
        controller.toggle(now: Date().addingTimeInterval(1))
        await settle(120)

        #expect(await transcriber.reloadCount == 1)
        #expect(controller.isProcessing == false)  // the session is released again
        #expect(panel.interactiveTexts.isEmpty)    // aborted decode yields no text
    }
}
