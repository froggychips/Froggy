// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Froggy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FroggyDaemon", targets: ["FroggyDaemon"]),
        .library(name: "VortexCore", targets: ["VortexCore"]),
        .library(name: "LushaBridge", targets: ["LushaBridge"])
    ],
    dependencies: [
        // Добавим зависимости для работы с MLX и системными API, когда они потребуются
    ],
    targets: [
        .executableTarget(
            name: "FroggyDaemon",
            dependencies: ["VortexCore", "LushaBridge"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-arch", "-Xlinker", "arm64"])
            ]
        ),
        .target(
            name: "VortexCore",
            dependencies: [],
            swiftSettings: [
                .define("ARM64")
            ]
        ),
        .target(
            name: "LushaBridge",
            dependencies: [],
            swiftSettings: [
                .define("ARM64")
            ]
        )
    ]
)
