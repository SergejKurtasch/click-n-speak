// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CNSAudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSAudio", targets: ["CNSAudio"]),
    ],
    dependencies: [
        .package(path: "../CNSCore"),
    ],
    targets: [
        .target(
            name: "CNSAudio",
            dependencies: ["CNSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSAudioTests",
            dependencies: ["CNSAudio"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
