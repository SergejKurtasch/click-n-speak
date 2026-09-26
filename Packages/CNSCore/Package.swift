// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CNSCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSCore", targets: ["CNSCore"]),
    ],
    targets: [
        .target(
            name: "CNSCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSCoreTests",
            dependencies: ["CNSCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
