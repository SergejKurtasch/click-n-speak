import Foundation

public enum UpdateChannel: String, Codable, Sendable, Equatable {
    case stable
    case beta
}

public enum UpdateArchitecture: String, Codable, Sendable, Equatable {
    case arm64
    case x86_64
    case universal

    public static var current: UpdateArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .universal
        #endif
    }
}

public struct AppUpdate: Sendable, Equatable {
    public let version: String
    public let downloadURL: URL
    public let releaseNotes: String
    public let publishedAt: Date
    public let sha256: String
    public let archiveSize: Int64
    public let architecture: UpdateArchitecture
    public let minimumMacOS: String
    public let channel: UpdateChannel
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(
        version: String,
        downloadURL: URL,
        releaseNotes: String,
        publishedAt: Date,
        sha256: String,
        archiveSize: Int64,
        architecture: UpdateArchitecture,
        minimumMacOS: String,
        channel: UpdateChannel,
        bundleIdentifier: String,
        teamIdentifier: String
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.sha256 = sha256.lowercased()
        self.archiveSize = archiveSize
        self.architecture = architecture
        self.minimumMacOS = minimumMacOS
        self.channel = channel
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct UpdateHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol UpdateHTTPClient: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse
}

public struct URLSessionUpdateHTTPClient: UpdateHTTPClient {
    public init() {}

    public func data(for request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= maximumBytes, let http = response as? HTTPURLResponse else {
            throw UpdateMetadataError.responseTooLarge
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        return UpdateHTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
    }
}

public enum UpdateMetadataError: LocalizedError, Sendable, Equatable {
    case invalidResponse(Int)
    case responseTooLarge
    case malformedRelease
    case missingManifest
    case malformedManifest
    case versionMismatch
    case unsupportedArchitecture
    case unsupportedOperatingSystem
    case wrongChannel
    case invalidChecksum
    case invalidArchiveSize
    case missingArchive
    case insecureURL
    case unexpectedBundleIdentifier

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(code): "Update server returned HTTP \(code)"
        case .responseTooLarge: "Update metadata exceeded the allowed size"
        case .malformedRelease: "Update release metadata is malformed"
        case .missingManifest: "The release is missing its artifact manifest"
        case .malformedManifest: "The release artifact manifest is malformed"
        case .versionMismatch: "The release and manifest versions do not match"
        case .unsupportedArchitecture: "The release does not support this Mac architecture"
        case .unsupportedOperatingSystem: "The release requires a newer macOS version"
        case .wrongChannel: "The release belongs to a different update channel"
        case .invalidChecksum: "The release checksum is invalid"
        case .invalidArchiveSize: "The release archive size is invalid"
        case .missingArchive: "The release archive described by the manifest is missing"
        case .insecureURL: "The release contains a non-HTTPS URL"
        case .unexpectedBundleIdentifier: "The release targets an unexpected application"
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let body: String
    let publishedAt: String
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case publishedAt = "published_at"
        case prerelease
        case assets
    }
}

private struct ReleaseArtifactManifest: Decodable {
    struct Archive: Decodable {
        let fileName: String
        let sha256: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case sha256
            case size
        }
    }

    let schemaVersion: Int
    let version: String
    let channel: UpdateChannel
    let architecture: UpdateArchitecture
    let minimumMacOS: String
    let bundleIdentifier: String
    let teamIdentifier: String
    let dmg: Archive

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case version
        case channel
        case architecture
        case minimumMacOS = "minimum_macos"
        case bundleIdentifier = "bundle_id"
        case teamIdentifier = "team_id"
        case dmg
    }
}

public struct UpdateCheckingService: Sendable {
    public static let defaultAPIURL = URL(
        string: "https://api.github.com/repos/SergejKurtasch/click-n-speak/releases/latest"
    )!

    private let client: any UpdateHTTPClient
    private let apiURL: URL
    private let maximumArchiveBytes: Int64

    public init(
        client: any UpdateHTTPClient = URLSessionUpdateHTTPClient(),
        apiURL: URL = Self.defaultAPIURL,
        maximumArchiveBytes: Int64 = 1_073_741_824
    ) {
        self.client = client
        self.apiURL = apiURL
        self.maximumArchiveBytes = maximumArchiveBytes
    }

    public func check(
        currentVersion: String,
        channel: UpdateChannel = .stable,
        architecture: UpdateArchitecture = .current,
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) async throws -> AppUpdate? {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let response = try await client.data(for: request, maximumBytes: 1_048_576)
        guard response.statusCode == 200 else {
            throw UpdateMetadataError.invalidResponse(response.statusCode)
        }
        let decoder = JSONDecoder()
        guard let release = try? decoder.decode(GitHubRelease.self, from: response.data),
              SemanticVersion(release.tagName) != nil else {
            throw UpdateMetadataError.malformedRelease
        }
        guard UpdateChecker.isVersion(release.tagName, newerThan: currentVersion) else { return nil }
        if channel == .stable, release.prerelease { throw UpdateMetadataError.wrongChannel }

        guard let manifestAsset = release.assets.first(where: {
            $0.name.lowercased().hasSuffix(".manifest.json")
        }) else {
            throw UpdateMetadataError.missingManifest
        }
        try ensureHTTPS(manifestAsset.browserDownloadURL)
        var manifestRequest = URLRequest(url: manifestAsset.browserDownloadURL)
        manifestRequest.timeoutInterval = 15
        let manifestResponse = try await client.data(for: manifestRequest, maximumBytes: 256 * 1_024)
        guard manifestResponse.statusCode == 200 else {
            throw UpdateMetadataError.invalidResponse(manifestResponse.statusCode)
        }
        guard let manifest = try? decoder.decode(ReleaseArtifactManifest.self, from: manifestResponse.data),
              manifest.schemaVersion == 1,
              !manifest.teamIdentifier.isEmpty else {
            throw UpdateMetadataError.malformedManifest
        }
        guard normalizedVersion(manifest.version) == normalizedVersion(release.tagName) else {
            throw UpdateMetadataError.versionMismatch
        }
        guard manifest.channel == channel else { throw UpdateMetadataError.wrongChannel }
        guard manifest.architecture == .universal || manifest.architecture == architecture else {
            throw UpdateMetadataError.unsupportedArchitecture
        }
        guard operatingSystemSatisfies(operatingSystem, minimum: manifest.minimumMacOS) else {
            throw UpdateMetadataError.unsupportedOperatingSystem
        }
        guard manifest.bundleIdentifier == "com.sergej.clicknspeak" else {
            throw UpdateMetadataError.unexpectedBundleIdentifier
        }
        guard manifest.dmg.sha256.count == 64,
              manifest.dmg.sha256.allSatisfy(\.isHexDigit) else {
            throw UpdateMetadataError.invalidChecksum
        }
        guard manifest.dmg.size > 0, manifest.dmg.size <= maximumArchiveBytes else {
            throw UpdateMetadataError.invalidArchiveSize
        }
        guard let archive = release.assets.first(where: { $0.name == manifest.dmg.fileName }),
              archive.size == manifest.dmg.size else {
            throw UpdateMetadataError.missingArchive
        }
        try ensureHTTPS(archive.browserDownloadURL)

        return AppUpdate(
            version: normalizedVersion(release.tagName),
            downloadURL: archive.browserDownloadURL,
            releaseNotes: release.body,
            publishedAt: ISO8601DateFormatter().date(from: release.publishedAt) ?? .distantPast,
            sha256: manifest.dmg.sha256,
            archiveSize: manifest.dmg.size,
            architecture: manifest.architecture,
            minimumMacOS: manifest.minimumMacOS,
            channel: manifest.channel,
            bundleIdentifier: manifest.bundleIdentifier,
            teamIdentifier: manifest.teamIdentifier
        )
    }

    private func ensureHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else { throw UpdateMetadataError.insecureURL }
    }

    private func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }

    private func operatingSystemSatisfies(
        _ current: OperatingSystemVersion,
        minimum: String
    ) -> Bool {
        let required = UpdateChecker.parseVersion(minimum)
        guard !required.isEmpty else { return false }
        let installed = [current.majorVersion, current.minorVersion, current.patchVersion]
        return !UpdateChecker.isRemote(required, newerThan: installed)
    }
}

private struct SemanticVersion: Comparable, Sendable {
    let components: [Int]
    let prerelease: [String]

    init?(_ source: String) {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let segments = cleaned.split(separator: "+", maxSplits: 1)
        let versionAndPrerelease = segments[0].split(separator: "-", maxSplits: 1)
        let core = versionAndPrerelease[0].split(separator: ".")
        guard !core.isEmpty, core.count <= 3,
              core.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        var values = core.compactMap { Int($0) }
        while values.count < 3 { values.append(0) }
        components = values
        prerelease = versionAndPrerelease.count == 2
            ? versionAndPrerelease[1].split(separator: ".").map(String.init)
            : []
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.components != rhs.components {
            return lhs.components.lexicographicallyPrecedes(rhs.components)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber < rightNumber
            }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public enum UpdateChecker {
    public static func check(currentVersion: String) async throws -> AppUpdate? {
        try await UpdateCheckingService().check(currentVersion: currentVersion)
    }

    static func parseVersion(_ version: String) -> [Int] {
        SemanticVersion(version)?.components ?? []
    }

    static func isRemote(_ remote: [Int], newerThan local: [Int]) -> Bool {
        let count = max(remote.count, local.count)
        for index in 0..<count {
            let remoteValue = index < remote.count ? remote[index] : 0
            let localValue = index < local.count ? local[index] : 0
            if remoteValue != localValue { return remoteValue > localValue }
        }
        return false
    }

    static func isVersion(_ remote: String, newerThan local: String) -> Bool {
        guard let remoteVersion = SemanticVersion(remote),
              let localVersion = SemanticVersion(local) else { return false }
        return remoteVersion > localVersion
    }
}
