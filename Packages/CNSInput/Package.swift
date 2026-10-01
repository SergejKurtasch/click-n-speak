// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CNSInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSInput", targets: ["CNSInput"]),
    ],
    dependencies: [
        .package(path: "../CNSCore"),
    ],
    targets: [
        .target(
            name: "CNSInput",
            dependencies: ["CNSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSInputTests",
            dependencies: ["CNSInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
