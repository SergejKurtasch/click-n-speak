// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClickNSpeak",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/CNSCore"),
        .package(path: "../Packages/CNSUI"),
    ],
    targets: [
        .executableTarget(
            name: "ClickNSpeak",
            dependencies: ["CNSCore", "CNSUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
