import AppKit
import CNSAudio
import CNSCore
import CNSTranscription
import CNSUI

/// Minimal record → chunk → transcribe → HUD coordinator for the Phase 2
/// milestone. It is deliberately thin: the full session state machine (append
/// mode, injection, overdue watchdog, session ids) is Phase 3's SessionController.
/// Wires the hotkey toggle to the recorder and streams chunk text into the HUD.
@MainActor
final class RecordingCoordinator {
    private let recorder: AudioRecorder
    private let transcriber: any Transcribing
    private let panel: PreviewPanel
    private let config: Config
    private let i18n: I18n
    private let log: @Sendable (String) -> Void

    private var isRecording = false
    private var transcript = ""

    init(
        config: Config,
        i18n: I18n,
        resources: AppResources,
        transcriber: any Transcribing,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.config = config
        self.i18n = i18n
        self.transcriber = transcriber
        self.panel = PreviewPanel(resources: resources)
        self.log = log

        let chunking = ChunkingConfig(
            silenceDuration: config.raw["silence_duration"]?.doubleValue ?? 1.0,
            targetSpeechDuration: config.raw["target_speech_duration"]?.doubleValue ?? 3.0,
            maxSpeechDuration: config.raw["max_speech_duration"]?.doubleValue ?? 8.0,
            minSpeechDuration: config.raw["min_speech_duration"]?.doubleValue ?? 0.5
        )
        self.recorder = AudioRecorder(config: chunking, log: { msg in log(msg) })
    }

    /// Hotkey handler: toggle recording on/off.
    func toggle() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        isRecording = true
        transcript = ""
        panel.show(title: i18n.t("hud.recording_title"))
        log("Recording started")

        let callbacks = AudioRecorder.Callbacks(
            onChunk: { [weak self] samples in
                Task { @MainActor in self?.handleChunk(samples, isFinal: false) }
            },
            onFinal: { [weak self] samples in
                Task { @MainActor in self?.handleFinal(samples) }
            }
        )
        do {
            try recorder.start(callbacks: callbacks)
        } catch {
            log("Recorder failed to start: \(error)")
            panel.updateStatus(i18n.t("hud.warmup_failed_title"))
            isRecording = false
        }
    }

    private func stop() {
        isRecording = false
        panel.updateStatus(i18n.t("hud.transcribing_title"))
        recorder.stop()
        log("Recording stopped")
    }

    private func handleChunk(_ samples: [Float], isFinal: Bool) {
        let request = TranscriptionRequest(
            audio: samples,
            initialPrompt: config.initialPrompt.isEmpty ? nil : config.initialPrompt,
            allowedLanguages: config.raw["language_auto_detect"]?.boolValue == true ? [] : [config.primaryLanguage],
            isFinalChunk: isFinal
        )
        Task { @MainActor in
            let result = await transcriber.transcribe(request)
            guard !result.text.isEmpty else { return }
            transcript = transcript.isEmpty ? result.text : transcript + " " + result.text
            panel.updateText(transcript)
        }
    }

    private func handleFinal(_ samples: [Float]?) {
        if let samples { handleChunk(samples, isFinal: true) }
        Task { @MainActor in
            // Give the final chunk a moment to transcribe, then close the HUD.
            try? await Task.sleep(nanoseconds: 300_000_000)
            panel.updateStatus(i18n.t("hud.ready_title"))
            panel.hide()
        }
    }
}
