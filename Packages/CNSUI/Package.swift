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
    ],
    targets: [
        .target(
            name: "CNSUI",
            dependencies: ["CNSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSUITests",
            dependencies: ["CNSUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
