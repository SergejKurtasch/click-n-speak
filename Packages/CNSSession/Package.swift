// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CNSSession",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSSession", targets: ["CNSSession"]),
    ],
    dependencies: [
        .package(path: "../CNSCore"),
        .package(path: "../CNSTranscription"),
        .package(path: "../CNSDictionary"),
    ],
    targets: [
        .target(
            name: "CNSSession",
            dependencies: ["CNSCore", "CNSTranscription", "CNSDictionary"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSSessionTests",
            dependencies: ["CNSSession", "CNSCore", "CNSDictionary", "CNSTranscription"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
