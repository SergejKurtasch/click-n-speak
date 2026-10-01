import Foundation
import XCTest
@testable import CNSCore

private struct FixtureUpdateHTTPClient: UpdateHTTPClient {
    let responses: [URL: UpdateHTTPResponse]

    func data(for request: URLRequest, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        guard let url = request.url, let response = responses[url] else {
            throw URLError(.resourceUnavailable)
        }
        guard response.data.count <= maximumBytes else {
            throw UpdateMetadataError.responseTooLarge
        }
        return response
    }
}

final class UpdateCheckerTests: XCTestCase {
    private let apiURL = URL(string: "https://api.example.invalid/releases/latest")!
    private let manifestURL = URL(string: "https://downloads.example.invalid/release.manifest.json")!
    private let archiveURL = URL(string: "https://downloads.example.invalid/Click-n-speak.dmg")!

    func testSemanticVersionComparisonDoesNotUseNetwork() {
        XCTAssertTrue(UpdateChecker.isVersion("v2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.1", newerThan: "1.2.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0", newerThan: "1.2.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isVersion("v1.2.0", newerThan: "1.2"))
        XCTAssertFalse(UpdateChecker.isVersion("1.1.9", newerThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("invalid", newerThan: "0.0.0"))
        XCTAssertEqual(UpdateChecker.parseVersion(" v1.2.3-beta.1 "), [1, 2, 3])
    }

    func testValidPinnedManifestProducesUpdate() async throws {
        let service = makeService(manifest: validManifest())
        let update = try await service.check(
            currentVersion: "1.0.0",
            architecture: .arm64,
            operatingSystem: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        )
        XCTAssertEqual(update?.version, "2.0.0")
        XCTAssertEqual(update?.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(update?.archiveSize, 123_456)
        XCTAssertEqual(update?.teamIdentifier, "ABCDE12345")
    }

    func testCurrentOrNewerVersionSkipsManifestRequest() async throws {
        let release = releaseData(version: "v2.0.0")
        let client = FixtureUpdateHTTPClient(responses: [
            apiURL: UpdateHTTPResponse(data: release, statusCode: 200),
        ])
        let service = UpdateCheckingService(client: client, apiURL: apiURL)
        let update = try await service.check(currentVersion: "2.0.0")
        XCTAssertNil(update)
    }

    func testMetadataFailureMatrix() async {
        let cases: [(String, [String: Any], UpdateMetadataError)] = [
            ("wrong architecture", validManifest(architecture: "x86_64"), .unsupportedArchitecture),
            ("minimum macOS", validManifest(minimumMacOS: "99.0"), .unsupportedOperatingSystem),
            ("wrong channel", validManifest(channel: "beta"), .wrongChannel),
            ("bad checksum", validManifest(checksum: "not-a-hash"), .invalidChecksum),
            ("oversized archive", validManifest(size: 2_000_000_000), .invalidArchiveSize),
            ("wrong bundle", validManifest(bundleID: "com.example.tampered"), .unexpectedBundleIdentifier),
        ]

        for (name, manifest, expected) in cases {
            do {
                _ = try await makeService(manifest: manifest).check(
                    currentVersion: "1.0.0",
                    architecture: .arm64,
                    operatingSystem: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
                )
                XCTFail("Expected failure for \(name)")
            } catch let error as UpdateMetadataError {
                XCTAssertEqual(error, expected, name)
            } catch {
                XCTFail("Unexpected error for \(name): \(error)")
            }
        }
    }

    func testArchiveSizeMustMatchReleaseAsset() async {
        let service = makeService(manifest: validManifest(size: 123_455))
        do {
            _ = try await service.check(currentVersion: "1.0.0", architecture: .arm64)
            XCTFail("Expected archive mismatch")
        } catch let error as UpdateMetadataError {
            XCTAssertEqual(error, .missingArchive)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeService(manifest: [String: Any]) -> UpdateCheckingService {
        let manifestData = try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let client = FixtureUpdateHTTPClient(responses: [
            apiURL: UpdateHTTPResponse(data: releaseData(version: "v2.0.0"), statusCode: 200),
            manifestURL: UpdateHTTPResponse(data: manifestData, statusCode: 200),
        ])
        return UpdateCheckingService(client: client, apiURL: apiURL)
    }

    private func releaseData(version: String) -> Data {
        let object: [String: Any] = [
            "tag_name": version,
            "body": "Release notes",
            "published_at": "2026-08-30T12:00:00Z",
            "prerelease": false,
            "assets": [
                [
                    "name": "release.manifest.json",
                    "browser_download_url": manifestURL.absoluteString,
                    "size": 900,
                ],
                [
                    "name": "Click-n-speak.dmg",
                    "browser_download_url": archiveURL.absoluteString,
                    "size": 123_456,
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validManifest(
        architecture: String = "arm64",
        minimumMacOS: String = "14.0",
        channel: String = "stable",
        checksum: String = String(repeating: "a", count: 64),
        size: Int64 = 123_456,
        bundleID: String = "com.sergej.clicknspeak"
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "version": "2.0.0",
            "channel": channel,
            "architecture": architecture,
            "minimum_macos": minimumMacOS,
            "bundle_id": bundleID,
            "team_id": "ABCDE12345",
            "dmg": [
                "file_name": "Click-n-speak.dmg",
                "sha256": checksum,
                "size": size,
            ],
        ]
    }
}
