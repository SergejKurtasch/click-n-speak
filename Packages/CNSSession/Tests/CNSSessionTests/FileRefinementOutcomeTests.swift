import Foundation
import Testing
import CNSCore
import CNSTranscription
@testable import CNSSession

@MainActor
private func makeFileSessionController(
    config: Config,
    transcriber: FakeTranscriber,
    aiEditor: FakeAiEditor?,
    runtimeDescriptor: RuntimeDescriptor
) -> SessionController {
    SessionController(
        config: config,
        transcriber: transcriber,
        aiEditor: aiEditor,
        recorder: FakeRecorder(),
        panel: FakePanel(),
        delivery: FakeDelivery(),
        frontmost: FakeFrontmost(),
        runtimeDescriptorProvider: { runtimeDescriptor }
    )
}

@Suite("File Refinement Outcomes")
struct FileRefinementOutcomeTests {
    private let url = URL(fileURLWithPath: "/tmp/test.wav")
    private let config = Config()
    
    @Test("Refine=false sets .notRequested and never calls editor")
    func notRequested() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "raw text", status: .success))
        let editor = FakeAiEditor()
        editor.refinedText = "refined text"
        let runtimeDescriptor = RuntimeDescriptor(
            transcriber: TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready),
            aiEditor: AiEditorDescriptor(backend: "mock", modelID: nil, kind: .cloud, readiness: .ready)
        )
        let sut = await makeFileSessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            runtimeDescriptor: runtimeDescriptor
        )
        
        let result = await sut.transcribeFile(url: url, refine: false, progress: { _ in })
        #expect(result.text == "raw text")
        #expect(result.refinement == .notRequested)
        #expect(result.status == .success)
        #expect(editor.didCallRefine == false)
    }

    @Test("Disabled editor maps to .unavailable and preserves raw text")
    func unavailable() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "raw text", status: .success))
        
        let sut = await SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: nil,
            recorder: FakeRecorder(),
            panel: await FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            runtimeDescriptorProvider: {
                let transcriber = TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready)
                let editor = AiEditorDescriptor(backend: "mock", modelID: nil, kind: .disabled, readiness: .ready)
                return RuntimeDescriptor(transcriber: transcriber, aiEditor: editor)
            }
        )
        
        let result = await sut.transcribeFile(url: url, refine: true, progress: { _ in })
        #expect(result.text == "raw text")
        #expect(result.refinement == .unavailable)
        #expect(result.status == .success)
    }

    @Test("STT failure skips refinement completely and maps to .notRun")
    func notRunOnFailure() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "", status: .failed(.init(kind: .fileDecode, message: "decode error"))))
        let editor = FakeAiEditor()
        
        let sut = await SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: await FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            runtimeDescriptorProvider: {
                let transcriber = TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready)
                let editor = AiEditorDescriptor(backend: "mock", modelID: nil, kind: .cloud, readiness: .ready)
                return RuntimeDescriptor(transcriber: transcriber, aiEditor: editor)
            }
        )
        
        let result = await sut.transcribeFile(url: url, refine: true, progress: { _ in })
        #expect(result.refinement == .notRun)
        if case .failed = result.status { } else { Issue.record("Expected failed") }
        #expect(editor.didCallRefine == false)
    }

    @Test("Editor timeout maps to .timedOut and preserves raw text")
    func timedOut() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "raw text", status: .success))
        let editor = FakeAiEditor()
        editor.refineStatus = .timeout
        editor.refinedText = "timed out text" // shouldn't be used
        
        let sut = await SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: await FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            runtimeDescriptorProvider: {
                let transcriber = TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready)
                let editor = AiEditorDescriptor(backend: "mock", modelID: nil, kind: .cloud, readiness: .ready)
                return RuntimeDescriptor(transcriber: transcriber, aiEditor: editor)
            }
        )
        
        let result = await sut.transcribeFile(url: url, refine: true, progress: { _ in })
        #expect(result.text == "raw text")
        #expect(result.refinement == .timedOut)
        #expect(result.status == .success)
    }

    @Test("Editor error maps to .failed and preserves raw text")
    func failed() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "raw text", status: .success))
        let editor = FakeAiEditor()
        editor.refineStatus = .error
        
        let sut = await SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: await FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            runtimeDescriptorProvider: {
                let transcriber = TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready)
                let editor = AiEditorDescriptor(backend: "mock", modelID: nil, kind: .cloud, readiness: .ready)
                return RuntimeDescriptor(transcriber: transcriber, aiEditor: editor)
            }
        )
        
        let result = await sut.transcribeFile(url: url, refine: true, progress: { _ in })
        #expect(result.text == "raw text")
        #expect(result.refinement == .failed)
        #expect(result.status == .success)
    }

    @Test("Editor success maps to .applied and uses refined text")
    func applied() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "raw text", status: .success))
        let editor = FakeAiEditor()
        editor.refineStatus = .ok
        editor.refinedText = "refined text"
        
        let sut = await SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: await FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            runtimeDescriptorProvider: {
                let transcriber = TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready)
                let editor = AiEditorDescriptor(backend: "mock", modelID: nil, kind: .cloud, readiness: .ready)
                return RuntimeDescriptor(transcriber: transcriber, aiEditor: editor)
            }
        )
        
        let result = await sut.transcribeFile(url: url, refine: true, progress: { _ in })
        #expect(result.text == "refined text")
        #expect(result.refinement == .applied)
        #expect(result.status == .success)
    }

    @Test("Editor unchanged maps to .unchanged and preserves raw text")
    func unchanged() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "raw text", status: .success))
        let editor = FakeAiEditor()
        editor.refineStatus = .unchanged
        editor.refinedText = "some other text"
        
        let sut = await SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: await FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            runtimeDescriptorProvider: {
                let transcriber = TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready)
                let editor = AiEditorDescriptor(backend: "mock", modelID: nil, kind: .cloud, readiness: .ready)
                return RuntimeDescriptor(transcriber: transcriber, aiEditor: editor)
            }
        )
        
        let result = await sut.transcribeFile(url: url, refine: true, progress: { _ in })
        #expect(result.text == "raw text")
        #expect(result.refinement == .unchanged)
        #expect(result.status == .success)
    }

    @Test("Editor skipped maps to .skipped and preserves raw text")
    func skipped() async throws {
        let transcriber = FakeTranscriber(fileResult: FileTranscriptionResult(text: "raw text", status: .success))
        let editor = FakeAiEditor()
        editor.refineStatus = .skipped
        
        let sut = await SessionController(
            config: config,
            transcriber: transcriber,
            aiEditor: editor,
            recorder: FakeRecorder(),
            panel: await FakePanel(),
            delivery: FakeDelivery(),
            frontmost: FakeFrontmost(),
            runtimeDescriptorProvider: {
                let transcriber = TranscriberDescriptor(backend: "mock", modelID: "mock", kind: .local, readiness: .ready)
                let editor = AiEditorDescriptor(backend: "mock", modelID: nil, kind: .cloud, readiness: .ready)
                return RuntimeDescriptor(transcriber: transcriber, aiEditor: editor)
            }
        )
        
        let result = await sut.transcribeFile(url: url, refine: true, progress: { _ in })
        #expect(result.text == "raw text")
        #expect(result.refinement == .skipped)
        #expect(result.status == .success)
    }
}
