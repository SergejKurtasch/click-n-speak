import CNSCore
import Foundation

public struct EditorHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol EditorHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> EditorHTTPResponse
    func stop() async
}

public extension EditorHTTPClient {
    func stop() async {}
}

public final class URLSessionEditorHTTPClient: EditorHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> EditorHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GeminiEditorError.invalidResponse
        }
        return EditorHTTPResponse(statusCode: response.statusCode, data: data)
    }

    public func stop() async { session.invalidateAndCancel() }
}

public enum GeminiEditorError: Error, Sendable {
    case invalidResponse
    case oversizedResponse
}

public actor GeminiEditor: AiEditing {
    public nonisolated let descriptor: AiEditorDescriptor
    private let readiness: LockedSnapshot<Bool>
    public nonisolated var isReady: Bool { readiness.get() }

    private let modelName: String
    private let apiKey: String
    private let realtimeClient: any EditorHTTPClient
    private let fileClient: any EditorHTTPClient
    private let overlapGate = InferenceExecutionGate()
    private let realtimeTimeout: TimeInterval
    private let fileTimeout: TimeInterval

    public init(
        modelName: String,
        apiKey: String,
        realtimeClient: (any EditorHTTPClient)? = nil,
        fileClient: (any EditorHTTPClient)? = nil,
        realtimeTimeout: TimeInterval = 15,
        fileTimeout: TimeInterval = 300
    ) {
        self.modelName = modelName
        self.apiKey = apiKey
        self.realtimeClient = realtimeClient ?? URLSessionEditorHTTPClient(
            requestTimeout: realtimeTimeout,
            resourceTimeout: realtimeTimeout
        )
        self.fileClient = fileClient ?? URLSessionEditorHTTPClient(
            requestTimeout: fileTimeout,
            resourceTimeout: fileTimeout
        )
        self.realtimeTimeout = realtimeTimeout
        self.fileTimeout = fileTimeout
        self.readiness = LockedSnapshot(!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        self.descriptor = AiEditorDescriptor(
            backend: "gemini",
            modelID: modelName,
            kind: .cloud
        )
    }

    public func prepare() async throws {
        readiness.set(!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RefineResult(text: text, status: .disabled)
        }
        guard let lease = overlapGate.tryAcquire() else {
            return RefineResult(text: text, status: .skipped)
        }
        return await execute(
            text: text,
            languages: languages,
            prompt: AiEditorPrompts.buildApiEditorSystemPrompt(
                languages: languages,
                knownTerms: knownTerms,
                misrecognitions: misrecognitions
            ),
            client: realtimeClient,
            timeout: realtimeTimeout,
            lease: lease
        )
    }

    public func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RefineResult(text: text, status: .disabled)
        }
        let lease: InferenceExecutionLease
        do {
            guard let acquired = try await overlapGate.acquire(timeout: EditorPolicy.fileGateTimeout) else {
                return RefineResult(text: text, status: .skipped)
            }
            lease = acquired
        } catch {
            return RefineResult(text: text, status: .skipped)
        }
        return await execute(
            text: text,
            languages: languages,
            prompt: AiEditorPrompts.buildFileSystemPromptGemini(
                languages: languages,
                knownTerms: knownTerms,
                misrecognitions: misrecognitions
            ),
            client: fileClient,
            timeout: fileTimeout,
            lease: lease
        )
    }

    public func stop() async {
        readiness.set(false)
        await realtimeClient.stop()
        await fileClient.stop()
    }

    private func execute(
        text: String,
        languages: [String]?,
        prompt: String,
        client: any EditorHTTPClient,
        timeout: TimeInterval,
        lease: InferenceExecutionLease
    ) async -> RefineResult {
        let request: URLRequest
        do {
            request = try makeRequest(
                text: text,
                languages: languages,
                systemPrompt: prompt,
                timeout: timeout
            )
        } catch {
            lease.release()
            return RefineResult(text: text, status: .error)
        }

        let operation = Task<RefineResult, Never> {
            defer { lease.release() }
            do {
                let response = try await client.send(request)
                guard (200..<300).contains(response.statusCode) else {
                    _ = response.data.prefix(8_192)
                    return RefineResult(text: text, status: .error)
                }
                guard response.data.count <= 2_000_000,
                      let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let output = parts.first?["text"] as? String else {
                    return RefineResult(text: text, status: .error)
                }
                return EditorPolicy.validatedOutput(output, original: text, multiplier: 3)
            } catch is CancellationError {
                return RefineResult(text: text, status: .skipped)
            } catch let error as URLError where error.code == .timedOut {
                return RefineResult(text: text, status: .timeout)
            } catch {
                return RefineResult(text: text, status: .error)
            }
        }
        return await AsyncDeadline.race(
            operation: operation,
            timeout: timeout,
            timeoutValue: RefineResult(text: text, status: .timeout)
        )
    }

    private func makeRequest(
        text: String,
        languages: [String]?,
        systemPrompt: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw GeminiEditorError.invalidResponse
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["parts": [["text": "<speech>\n\(text)\n</speech>"]]]],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": Self.estimateTokens(text: text, languages: languages),
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func estimateTokens(text: String, languages: [String]?) -> Int {
        let languages = Set(languages ?? [])
        let cjk: Set<String> = ["zh", "ja", "ko"]
        let cyrillic: Set<String> = ["ru", "uk"]
        let charactersPerToken: Double
        if !languages.isDisjoint(with: cjk) {
            charactersPerToken = 1.5
        } else if !languages.isDisjoint(with: cyrillic) {
            charactersPerToken = 2.5
        } else if !languages.isEmpty {
            charactersPerToken = 3.5
        } else {
            charactersPerToken = 2.5
        }
        return max(64, Int(Double(text.count) / charactersPerToken * 1.2))
    }
}
