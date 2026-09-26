import Foundation
import Security

public struct CandidateVerificationPolicy: Sendable, Equatable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let currentVersion: String
    public let architecture: UpdateArchitecture
    public let allowedEntitlements: Set<String>

    public init(
        bundleIdentifier: String,
        teamIdentifier: String,
        currentVersion: String,
        architecture: UpdateArchitecture,
        allowedEntitlements: Set<String> = [
            "com.apple.security.automation.apple-events",
            "com.apple.security.device.audio-input",
            "com.apple.security.network.client",
        ]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.currentVersion = currentVersion
        self.architecture = architecture
        self.allowedEntitlements = allowedEntitlements
    }
}

public struct CandidateBundleMetadata: Sendable, Equatable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let version: String
    public let architectures: Set<UpdateArchitecture>
    public let signatureValid: Bool
    public let hardenedRuntime: Bool
    public let notarized: Bool
    public let entitlements: Set<String>
    public let hasUnexpectedHelpers: Bool

    public init(
        bundleIdentifier: String,
        teamIdentifier: String,
        version: String,
        architectures: Set<UpdateArchitecture>,
        signatureValid: Bool,
        hardenedRuntime: Bool,
        notarized: Bool,
        entitlements: Set<String>,
        hasUnexpectedHelpers: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.version = version
        self.architectures = architectures
        self.signatureValid = signatureValid
        self.hardenedRuntime = hardenedRuntime
        self.notarized = notarized
        self.entitlements = entitlements
        self.hasUnexpectedHelpers = hasUnexpectedHelpers
    }
}

public enum CandidateVerificationError: LocalizedError, Sendable, Equatable {
    case invalidBundle
    case wrongBundleIdentifier
    case wrongTeamIdentifier
    case invalidSignature
    case hardenedRuntimeMissing
    case notarizationMissing
    case unsupportedArchitecture
    case versionNotNewer
    case unexpectedEntitlements([String])
    case unexpectedHelperPayload
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundle: "The update does not contain a valid application bundle"
        case .wrongBundleIdentifier: "The update has an unexpected bundle identifier"
        case .wrongTeamIdentifier: "The update was signed by an unexpected developer team"
        case .invalidSignature: "The update code signature is invalid"
        case .hardenedRuntimeMissing: "The update does not enable the hardened runtime"
        case .notarizationMissing: "Gatekeeper did not accept the update"
        case .unsupportedArchitecture: "The update does not contain the required executable architecture"
        case .versionNotNewer: "The update version is not newer than the installed version"
        case let .unexpectedEntitlements(values): "The update contains unexpected entitlements: \(values.joined(separator: ", "))"
        case .unexpectedHelperPayload: "The update contains an unexpected privileged helper payload"
        case let .commandFailed(command): "Update verification command failed: \(command)"
        }
    }
}

public protocol UpdateCandidateVerifying: Sendable {
    func verify(candidateURL: URL, policy: CandidateVerificationPolicy) async throws
}

public enum CandidateMetadataValidator {
    public static func validate(
        _ metadata: CandidateBundleMetadata,
        policy: CandidateVerificationPolicy
    ) throws {
        guard metadata.bundleIdentifier == policy.bundleIdentifier else {
            throw CandidateVerificationError.wrongBundleIdentifier
        }
        guard metadata.teamIdentifier == policy.teamIdentifier else {
            throw CandidateVerificationError.wrongTeamIdentifier
        }
        guard metadata.signatureValid else { throw CandidateVerificationError.invalidSignature }
        guard metadata.hardenedRuntime else { throw CandidateVerificationError.hardenedRuntimeMissing }
        guard metadata.notarized else { throw CandidateVerificationError.notarizationMissing }
        let architectureMatches = metadata.architectures.contains(.universal)
            || metadata.architectures.contains(policy.architecture)
        guard architectureMatches else { throw CandidateVerificationError.unsupportedArchitecture }
        guard UpdateChecker.isVersion(metadata.version, newerThan: policy.currentVersion) else {
            throw CandidateVerificationError.versionNotNewer
        }
        let unexpected = metadata.entitlements.subtracting(policy.allowedEntitlements).sorted()
        guard unexpected.isEmpty else {
            throw CandidateVerificationError.unexpectedEntitlements(unexpected)
        }
        guard !metadata.hasUnexpectedHelpers else {
            throw CandidateVerificationError.unexpectedHelperPayload
        }
    }
}

/// Production candidate inspection uses Security.framework for the designated
/// requirement and nested signature, plus Gatekeeper and lipo for notarization
/// and architecture assessment.
public struct SystemUpdateCandidateVerifier: UpdateCandidateVerifying {
    public init() {}

    public func verify(candidateURL: URL, policy: CandidateVerificationPolicy) async throws {
        let metadata = try await Task.detached(priority: .utility) {
            try inspect(candidateURL: candidateURL, policy: policy)
        }.value
        try CandidateMetadataValidator.validate(metadata, policy: policy)
    }

    private func inspect(
        candidateURL: URL,
        policy: CandidateVerificationPolicy
    ) throws -> CandidateBundleMetadata {
        guard let bundle = Bundle(url: candidateURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let executableURL = bundle.executableURL else {
            throw CandidateVerificationError.invalidBundle
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidateURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw CandidateVerificationError.invalidSignature
        }
        let requirementText = "identifier \"\(policy.bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(policy.teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw CandidateVerificationError.invalidSignature
        }
        let securityValid = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: 0),
            requirement
        ) == errSecSuccess
        let nestedSignatureValid: Bool
        do {
            _ = try run(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", candidateURL.path]
            )
            nestedSignatureValid = true
        } catch {
            nestedSignatureValid = false
        }
        let signatureValid = securityValid && nestedSignatureValid

        var signingInformation: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        let signing = signingInformation as? [String: Any]
        let teamID = signing?[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        let codeFlags = (signing?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let hardenedRuntime = codeFlags & 0x0001_0000 != 0
        let entitlementDictionary = signing?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let entitlements = Set(entitlementDictionary?.keys ?? Dictionary<String, Any>().keys)

        let architectureOutput = try run(
            executable: "/usr/bin/lipo",
            arguments: ["-archs", executableURL.path]
        )
        let architectures = Set(architectureOutput.split(whereSeparator: \.isWhitespace).compactMap {
            UpdateArchitecture(rawValue: String($0))
        })

        let gatekeeperAccepted: Bool
        do {
            _ = try run(
                executable: "/usr/sbin/spctl",
                arguments: ["--assess", "--type", "execute", "--verbose=2", candidateURL.path]
            )
            gatekeeperAccepted = true
        } catch {
            gatekeeperAccepted = false
        }

        let fm = FileManager.default
        let forbidden = [
            "Contents/Library/PrivilegedHelperTools",
            "Contents/Library/LaunchDaemons",
            "Contents/Library/SystemExtensions",
        ]
        let hasUnexpectedHelpers = forbidden.contains {
            fm.fileExists(atPath: candidateURL.appendingPathComponent($0).path)
        }

        guard signingStatus == errSecSuccess else {
            throw CandidateVerificationError.invalidSignature
        }
        return CandidateBundleMetadata(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamID,
            version: version,
            architectures: architectures,
            signatureValid: signatureValid,
            hardenedRuntime: hardenedRuntime,
            notarized: gatekeeperAccepted,
            entitlements: entitlements,
            hasUnexpectedHelpers: hasUnexpectedHelpers
        )
    }

    private func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CandidateVerificationError.commandFailed(executable)
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
