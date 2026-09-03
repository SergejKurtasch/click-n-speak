import CNSCore
import CNSEditors
import Foundation

enum EditorTestError: Error { case expected }

struct FixedMemoryPressure: MemoryPressureProviding {
    let high: Bool
    func isHigh() -> Bool { high }
}

actor ScriptedLocalGenerator: LocalTextGenerating {
    enum Behavior: Sendable {
        case output(String)
        case failure
        case delayed(String, TimeInterval)
    }

    private var behaviors: [Behavior]
    private(set) var callCount = 0
    private(set) var stopCount = 0
    private(set) var prompts: [String] = []

    init(_ behaviors: [Behavior]) { self.behaviors = behaviors }

    func prepare() async throws {}

    func generate(systemPrompt: String, text: String, maximumTokens: Int) async throws -> String {
        callCount += 1
        prompts.append(systemPrompt)
        let behavior = behaviors.isEmpty ? .output(text) : behaviors.removeFirst()
        switch behavior {
        case let .output(output):
            return output
        case .failure:
            throw EditorTestError.expected
        case let .delayed(output, delay):
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    continuation.resume(returning: output)
                }
            }
        }
    }

    func stop() async { stopCount += 1 }
}

final class ScriptedEditorHTTPClient: EditorHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [EditorHTTPResponse]
    private let delay: TimeInterval
    private var requestsStorage: [URLRequest] = []
    private var stopCountStorage = 0

    init(responses: [EditorHTTPResponse], delay: TimeInterval = 0) {
        self.responses = responses
        self.delay = delay
    }

    var requests: [URLRequest] { lock.withLock { requestsStorage } }
    var callCount: Int { lock.withLock { requestsStorage.count } }
    var stopCount: Int { lock.withLock { stopCountStorage } }

    func send(_ request: URLRequest) async throws -> EditorHTTPResponse {
        let response = lock.withLock { () -> EditorHTTPResponse in
            requestsStorage.append(request)
            return responses.isEmpty
                ? EditorHTTPResponse.success(text: "unchanged")
                : responses.removeFirst()
        }
        guard delay > 0 else { return response }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                continuation.resume(returning: response)
            }
        }
    }

    func stop() async { lock.withLock { stopCountStorage += 1 } }

}

extension EditorHTTPResponse {
    static func success(text: String) -> EditorHTTPResponse {
        let object: [String: Any] = [
            "candidates": [["content": ["parts": [["text": text]]]]],
        ]
        return EditorHTTPResponse(
            statusCode: 200,
            data: try! JSONSerialization.data(withJSONObject: object)
        )
    }
}

enum EditorSnapshotFixture {
    static func make() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(file))
        }
        return directory
    }
}

let longEditorInput = "this is a sufficiently long speech transcript for deterministic editor testing and it contains enough meaningful words to pass the conservative local input filter"
