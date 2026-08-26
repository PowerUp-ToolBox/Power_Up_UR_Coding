// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PowerUp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PowerUp",
            path: "Sources/PowerUp"
        ),
        .testTarget(
            name: "PowerUpTests",
            dependencies: ["PowerUp"],
            path: "Tests/PowerUpTests"
        )
    ]
)
