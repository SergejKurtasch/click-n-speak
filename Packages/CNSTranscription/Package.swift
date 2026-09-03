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
        // Vendored whisper.cpp static library + Metal (built by
        // scripts/build_whisper_xcframework.sh). Gitignored — regenerate locally.
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .target(
            name: "CNSTranscription",
            dependencies: [
                "CNSCore",
                "whisper",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // ggml/whisper.cpp are C++; pull in the C++ standard library.
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "CNSTranscriptionTests",
            dependencies: ["CNSTranscription", "CNSCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
