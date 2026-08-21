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
        .package(path: "../CNSAudio"),
        .package(path: "../CNSTranscription"),
        .package(path: "../CNSInput"),
        .package(path: "../CNSUI"),
        .package(path: "../CNSDictionary"),
    ],
    targets: [
        .target(
            name: "CNSSession",
            dependencies: ["CNSCore", "CNSAudio", "CNSTranscription", "CNSInput", "CNSUI", "CNSDictionary"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSSessionTests",
            dependencies: ["CNSSession", "CNSCore", "CNSTranscription", "CNSAudio", "CNSUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
