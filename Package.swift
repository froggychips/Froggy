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
        .executable(name: "FroggyMLXWorker", targets: ["FroggyMLXWorker"]),
        .executable(name: "froggy", targets: ["FroggyCLI"]),
        .library(name: "VortexCore", targets: ["VortexCore"]),
        .library(name: "LushaBridge", targets: ["LushaBridge"]),
        .library(name: "MLXWorkerProtocol", targets: ["MLXWorkerProtocol"]),
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
        .executableTarget(
            name: "FroggyCLI",
            dependencies: ["VortexCore"],
            swiftSettings: strictConcurrency
        ),
        // Worker — единственный таргет, тащащий MLX runtime. Демон убивает
        // его на unloadModel, и unified memory возвращается ядру.
        //
        // Metal-shader'ы (`default.metallib`) собираются `scripts/compile-metallib.sh`
        // и копируются в `.build/release/Resources/` через `make build`,
        // откуда mlx-swift находит их по своему 4-му search-path
        // (co-located <binary-dir>/Resources/). SwiftPM resource declaration
        // здесь НЕ работает — bundle-структура SwiftPM не регистрируется
        // в `NSBundle.allBundles`, и mlx-swift не итерирует через неё.
        // См. ADR 0013 для деталей.
        .executableTarget(
            name: "FroggyMLXWorker",
            dependencies: [
                "MLXWorkerProtocol",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: strictConcurrency
        ),
        // Тестовый-двойник без MLX — для интеграционных тестов supervisor'a.
        .executableTarget(
            name: "FroggyMLXWorkerFake",
            dependencies: ["MLXWorkerProtocol"],
            swiftSettings: strictConcurrency
        ),
        // Общий протокол wire-формата — ни демон, ни worker не должны
        // знать друг о друге; оба знают про этот target.
        .target(
            name: "MLXWorkerProtocol",
            dependencies: [],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "VortexCore",
            dependencies: ["MLXWorkerProtocol"],
            swiftSettings: strictConcurrency,
            linkerSettings: [
                // sqlite3 для FreezeStatsStore — Mem-5 telemetry. macOS его
                // ships в системе, без новых SwiftPM deps.
                .linkedLibrary("sqlite3"),
            ]
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
        // Verify default.metallib is bundled with FroggyMLXWorker — иначе
        // worker умирает на первой реальной MLX-операции (см. ADR 0013).
        // Тест всегда зелёный после `make build`; красный означает что
        // pre-build шаг (`scripts/compile-metallib.sh`) не отработал.
        .testTarget(
            name: "MLXWorkerMetallibTests",
            dependencies: [],
            swiftSettings: strictConcurrency
        ),
    ]
)
