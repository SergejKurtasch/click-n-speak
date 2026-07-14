// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClickNSpeak",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/CNSCore"),
        .package(path: "../Packages/CNSUI"),
        .package(path: "../Packages/CNSAudio"),
        .package(path: "../Packages/CNSTranscription"),
        .package(path: "../Packages/CNSInput"),
    ],
    targets: [
        .executableTarget(
            name: "ClickNSpeak",
            dependencies: ["CNSCore", "CNSUI", "CNSAudio", "CNSTranscription", "CNSInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
