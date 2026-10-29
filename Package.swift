// swift-tools-version:5.9
import Foundation
import PackageDescription

// The Rust core (ADR 0012) is part of every build since slice 2.2. Its bridge
// is built by ./scripts/build-core.sh into rust/build/; a checkout without it
// stops here with the fix, instead of with SwiftPM's "missing binary artifact".
// SwiftPM caches a passing evaluation, so a bridge deleted after a good build
// still shows SwiftPM's own error; the fix is the same.
for path in ["rust/build/PowerUpCoreFFI.xcframework", "rust/build/swift/PowerUpCore.swift"]
where !FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + path) {
    fatalError("""
        PowerUp needs its Rust core, and \(path) is missing. \
        Run ./scripts/build-core.sh first (it needs Rust from https://rustup.rs \
        and a full Xcode install), then build again.
        """)
}

let package = Package(
    name: "PowerUp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PowerUp",
            dependencies: ["PowerUpCore"],
            path: "Sources/PowerUp"
        ),
        .testTarget(
            name: "PowerUpTests",
            dependencies: ["PowerUp"],
            path: "Tests/PowerUpTests"
        ),
        .binaryTarget(
            name: "PowerUpCoreFFI",
            path: "rust/build/PowerUpCoreFFI.xcframework"
        ),
        .target(
            name: "PowerUpCore",
            dependencies: ["PowerUpCoreFFI"],
            path: "rust/build/swift"
        ),
        .testTarget(
            name: "PowerUpCoreTests",
            dependencies: ["PowerUpCore"],
            path: "Tests/PowerUpCoreTests"
        )
    ]
)
