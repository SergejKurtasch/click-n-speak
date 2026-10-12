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
        // Vendored libfvad (BSD-3, WebRTC-derived): the same VAD algorithm the
        // Python app uses via webrtcvad, so the chunking thresholds carry over
        // without recalibration. Pure C, compiled from source — no prebuilt binary.
        .target(name: "Cfvad"),
        .target(name: "CNSObjCExceptionCatcher"),
        .target(
            name: "CNSAudio",
            dependencies: ["CNSCore", "Cfvad", "CNSObjCExceptionCatcher"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSAudioTests",
            dependencies: ["CNSAudio", "CNSObjCExceptionCatcher"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
