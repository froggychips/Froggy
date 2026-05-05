// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Froggy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FroggyDaemon", targets: ["FroggyDaemon"]),
        .library(name: "VortexCore", targets: ["VortexCore"]),
        .library(name: "LushaBridge", targets: ["LushaBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.20.0")
    ],
    targets: [
        .executableTarget(
            name: "FroggyDaemon",
            dependencies: ["VortexCore", "LushaBridge"]),
        .target(
            name: "VortexCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift")
            ]),
        .target(
            name: "LushaBridge",
            dependencies: [])
    ]
)
