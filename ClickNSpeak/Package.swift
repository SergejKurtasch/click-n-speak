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
        .package(path: "../Packages/CNSEditors"),
        .package(path: "../Packages/CNSInput"),
        .package(path: "../Packages/CNSDictionary"),
        .package(path: "../Packages/CNSSession"),
    ],
    targets: [
        .executableTarget(
            name: "ClickNSpeak",
            dependencies: ["CNSCore", "CNSUI", "CNSAudio", "CNSTranscription", "CNSEditors", "CNSInput", "CNSDictionary", "CNSSession"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CNSUpdateHelper",
            dependencies: ["CNSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClickNSpeakTests",
            dependencies: [
                "ClickNSpeak",
                .product(name: "CNSCore", package: "CNSCore"),
                .product(name: "CNSDictionary", package: "CNSDictionary"),
                .product(name: "CNSTranscription", package: "CNSTranscription"),
                .product(name: "CNSEditors", package: "CNSEditors"),
                .product(name: "CNSSession", package: "CNSSession"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
