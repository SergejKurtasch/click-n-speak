// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CNSUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSUI", targets: ["CNSUI"]),
    ],
    dependencies: [
        .package(path: "../CNSCore"),
        .package(path: "../CNSDictionary"),
        .package(path: "../CNSTranscription"),
    ],
    targets: [
        .target(
            name: "CNSUI",
            dependencies: ["CNSCore", "CNSDictionary", "CNSTranscription"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSUITests",
            dependencies: ["CNSUI", "CNSCore", "CNSDictionary", "CNSTranscription"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
