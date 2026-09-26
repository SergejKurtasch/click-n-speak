import CNSCore
import Foundation
import Testing
@testable import CNSEditors

@Suite("Gemini AI editor")
struct GeminiEditorTests {
    @Test("Default cloud prewarm never sends HTTP")
    func prewarmNeverSendsHTTP() async {
        let client = ScriptedEditorHTTPClient(responses: [])
        let editor = GeminiEditor(modelName: "gemini-test", apiKey: "key", realtimeClient: client, fileClient: client)
        #expect(await editor.preWarm(languages: ["ru", "en"], force: true) == .skipped)
        #expect(client.callCount == 0)
    }

    @Test("Initialization and every HTTP result preserve the original on fallback")
    func statusMatrix() async {
        let disabled = GeminiEditor(modelName: "gemini-test", apiKey: "")
        #expect(!disabled.isReady)
        #expect(await disabled.refine(text: longEditorInput, languages: nil, knownTerms: nil, misrecognitions: nil).status == .disabled)

        let unchangedClient = ScriptedEditorHTTPClient(responses: [.success(text: longEditorInput)])
        let unchanged = GeminiEditor(
            modelName: "gemini-test",
            apiKey: "key",
            realtimeClient: unchangedClient,
            fileClient: unchangedClient
        )
        #expect(unchanged.isReady)
        #expect(await unchanged.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil) == RefineResult(text: longEditorInput, status: .unchanged))

        let improved = longEditorInput + "."
        let okClient = ScriptedEditorHTTPClient(responses: [.success(text: improved)])
        let ok = GeminiEditor(modelName: "gemini-test", apiKey: "key", realtimeClient: okClient, fileClient: okClient)
        #expect(await ok.refine(text: longEditorInput, languages: ["en"], knownTerms: nil, misrecognitions: nil) == RefineResult(text: improved, status: .ok))

        let unauthorizedClient = ScriptedEditorHTTPClient(responses: [
            EditorHTTPResponse(statusCode: 401, data: Data(repeating: 0x41, count: 20_000)),
        ])
        let unauthorized = GeminiEditor(modelName: "gemini-test", apiKey: "key", realtimeClient: unauthorizedClient, fileClient: unauthorizedClient)
        #expect(await unauthorized.refine(text: longEditorInput, languages: nil, knownTerms: nil, misrecognitions: nil) == RefineResult(text: longEditorInput, status: .error))

        let malformedClient = ScriptedEditorHTTPClient(responses: [
            EditorHTTPResponse(statusCode: 200, data: Data("{}".utf8)),
        ])
        let malformed = GeminiEditor(modelName: "gemini-test", apiKey: "key", realtimeClient: malformedClient, fileClient: malformedClient)
        #expect(await malformed.refine(text: longEditorInput, languages: nil, knownTerms: nil, misrecognitions: nil).status == .error)
    }

    @Test("Caller timeout keeps the overlap gate held until HTTP completion")
    func timeoutRetainsOverlapGate() async throws {
        let client = ScriptedEditorHTTPClient(
            responses: [.success(text: longEditorInput + "."), .success(text: longEditorInput + ".")],
            delay: 0.12
        )
        let editor = GeminiEditor(
            modelName: "gemini-test",
            apiKey: "key",
            realtimeClient: client,
            fileClient: client,
            realtimeTimeout: 0.02,
            fileTimeout: 0.5
        )

        let first = await editor.refine(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(first == RefineResult(text: longEditorInput, status: .timeout))
        let second = await editor.refine(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(second.status == .skipped)
        #expect(client.callCount == 1)

        try await Task.sleep(for: .milliseconds(140))
        let third = await editor.refineFileText(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(third.status == .ok)
        #expect(client.callCount == 2)
    }

    @Test("Cloud editor ignores the local Metal gate and sends vocabulary hints")
    func cloudDoesNotUseMetalGate() async throws {
        let metalGate = InferenceExecutionGate()
        let whisperLease = try #require(metalGate.tryAcquire())
        defer { whisperLease.release() }

        let client = ScriptedEditorHTTPClient(responses: [.success(text: longEditorInput + ".")])
        let editor = GeminiEditor(
            modelName: "gemini-test",
            apiKey: "secret",
            realtimeClient: client,
            fileClient: client
        )
        let result = await editor.refine(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: ["Click-n-speak", "MLX"],
            misrecognitions: [("click and speak", "Click-n-speak")]
        )
        #expect(result.status == .ok)
        let request = try #require(client.requests.first)
        let body = try #require(request.httpBody)
        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(bodyText.contains("KNOWN TERMS"))
        #expect(bodyText.contains("COMMON MISRECOGNITIONS"))
        #expect(bodyText.contains("Click-n-speak"))
        #expect(!bodyText.contains("secret"))
    }

    @Test("File mode uses its independent client and timeout policy")
    func fileClientIsIndependent() async {
        let realtime = ScriptedEditorHTTPClient(responses: [.success(text: "unused")])
        let file = ScriptedEditorHTTPClient(responses: [.success(text: longEditorInput + ".")])
        let editor = GeminiEditor(
            modelName: "gemini-test",
            apiKey: "key",
            realtimeClient: realtime,
            fileClient: file,
            realtimeTimeout: 0.01,
            fileTimeout: 0.5
        )
        let result = await editor.refineFileText(
            text: longEditorInput,
            languages: ["en"],
            knownTerms: nil,
            misrecognitions: nil
        )
        #expect(result.status == .ok)
        #expect(realtime.callCount == 0)
        #expect(file.callCount == 1)
        #expect(file.requests.first?.timeoutInterval == 0.5)
    }

    @Test("Cancelling active file refinement reaches the HTTP client")
    func activeFileCancellationReachesHTTPClient() async {
        let client = ScriptedEditorHTTPClient(
            responses: [.success(text: longEditorInput + ".")],
            waitForCancellation: true
        )
        let editor = GeminiEditor(
            modelName: "gemini-test",
            apiKey: "key",
            realtimeClient: client,
            fileClient: client,
            fileTimeout: 5
        )
        let task = Task {
            await editor.refineFileText(
                text: longEditorInput,
                languages: ["en"],
                knownTerms: nil,
                misrecognitions: nil
            )
        }
        while client.callCount == 0 { await Task.yield() }

        task.cancel()
        let result = await task.value
        while client.cancellationCount == 0 { await Task.yield() }

        #expect(result.text == longEditorInput)
        #expect(result.status == .timeout)
        #expect(client.cancellationCount == 1)
    }
}
