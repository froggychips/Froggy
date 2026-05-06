// swift-tools-version: 6.0
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Froggy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FroggyDaemon", targets: ["FroggyDaemon"]),
        .executable(name: "FroggyMenuBar", targets: ["FroggyMenuBar"]),
        .library(name: "VortexCore", targets: ["VortexCore"]),
        .library(name: "LushaBridge", targets: ["LushaBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "FroggyDaemon",
            dependencies: ["VortexCore", "LushaBridge"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "FroggyMenuBar",
            dependencies: ["VortexCore"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "VortexCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "LushaBridge",
            dependencies: [],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "VortexCoreTests",
            dependencies: ["VortexCore"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "LushaBridgeTests",
            dependencies: ["LushaBridge"],
            swiftSettings: strictConcurrency
        ),
    ]
)
