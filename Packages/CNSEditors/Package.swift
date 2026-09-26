// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CNSEditors",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CNSEditors", targets: ["CNSEditors"]),
    ],
    dependencies: [
        .package(path: "../CNSCore"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            exact: "3.31.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "CNSEditors",
            dependencies: [
                "CNSCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNSEditorsTests",
            dependencies: ["CNSEditors", "CNSCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
