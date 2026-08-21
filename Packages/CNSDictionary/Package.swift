// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CNSDictionary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSDictionary", targets: ["CNSDictionary"]),
    ],
    dependencies: [
        .package(path: "../CNSCore"),
    ],
    targets: [
        .target(
            name: "CNSDictionary",
            dependencies: ["CNSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSDictionaryTests",
            dependencies: ["CNSDictionary"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
