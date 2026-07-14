// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CNSTranscription",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSTranscription", targets: ["CNSTranscription"]),
    ],
    dependencies: [
        .package(path: "../CNSCore"),
    ],
    targets: [
        .target(
            name: "CNSTranscription",
            dependencies: ["CNSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSTranscriptionTests",
            dependencies: ["CNSTranscription"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
