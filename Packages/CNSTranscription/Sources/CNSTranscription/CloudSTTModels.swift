import Foundation

public enum CloudSTTBackend: String, Sendable {
    case gemini = "gemini"
    case openai = "openai"
}

public enum CloudSTTModels {
    public static let gemini: [(displayName: String, modelId: String)] = [
        ("Gemini 2.5 Flash-Lite", "gemini-2.5-flash-lite"),
        ("Gemini 2.5 Flash", "gemini-2.5-flash"),
        ("Gemini 3 Flash", "gemini-3-flash"),
    ]
    public static let openai: [(displayName: String, modelId: String)] = [
        ("GPT-4o mini Transcribe", "gpt-4o-mini-transcribe"),
        ("GPT-4o Transcribe", "gpt-4o-transcribe"),
        ("Whisper-1", "whisper-1"),
    ]
}

public struct HTTPDataResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol HTTPDataClient: Sendable {
    func data(for request: URLRequest) async throws -> HTTPDataResponse
}

public final class URLSessionHTTPDataClient: HTTPDataClient, @unchecked Sendable {
    private let session: URLSession
    private let maximumSuccessBytes: Int
    private let maximumErrorBytes: Int

    public init(
        session: URLSession,
        maximumSuccessBytes: Int = 32 * 1_024 * 1_024,
        maximumErrorBytes: Int = 4_096
    ) {
        self.session = session
        self.maximumSuccessBytes = maximumSuccessBytes
        self.maximumErrorBytes = maximumErrorBytes
    }

    public func data(for request: URLRequest) async throws -> HTTPDataResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let limit = (200..<300).contains(response.statusCode)
            ? maximumSuccessBytes
            : maximumErrorBytes
        var data = Data()
        data.reserveCapacity(min(limit, response.expectedContentLength > 0
            ? Int(response.expectedContentLength)
            : limit))
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return HTTPDataResponse(statusCode: response.statusCode, data: data)
    }
}

public struct CloudSTTTimeouts: Sendable, Equatable {
    public var connect: TimeInterval
    public var request: TimeInterval
    public var resource: TimeInterval

    public init(connect: TimeInterval, request: TimeInterval, resource: TimeInterval) {
        self.connect = connect
        self.request = request
        self.resource = resource
    }

    public static let realtime = CloudSTTTimeouts(connect: 10, request: 30, resource: 60)
    public static let file = CloudSTTTimeouts(connect: 20, request: 120, resource: 600)

    public func makeClient() -> URLSessionHTTPDataClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = connect
        configuration.timeoutIntervalForResource = resource
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSessionHTTPDataClient(session: URLSession(configuration: configuration))
    }
}

public struct CloudRetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.25) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
    }

    public func delay(after attempt: Int, jitter: Double) -> TimeInterval {
        baseDelay * pow(2, Double(max(0, attempt - 1))) * (0.75 + 0.5 * jitter)
    }
}
