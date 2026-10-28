// swift-tools-version:5.9
import PackageDescription

// The Rust core (stage 2.1, ADR 0012) links in when POWERUP_CORE=1 is set and
// ./scripts/build-core.sh has produced its bridge (scripts/build.sh does both).
// Until slice 2.2 makes the core mandatory, a plain `swift build` builds the
// app without it. An environment switch rather than a file check, because
// SwiftPM caches this manifest's result and would not see the bridge appear.
let coreIsBuilt = Context.environment["POWERUP_CORE"] == "1"

var appDependencies: [Target.Dependency] = []
var appSettings: [SwiftSetting] = []
var coreTargets: [Target] = []
if coreIsBuilt {
    appDependencies.append("PowerUpCore")
    // Not `canImport`: a module left in .build by an earlier core build would
    // satisfy it after the core is switched off.
    appSettings.append(.define("POWERUP_CORE"))
    coreTargets = [
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
}

let package = Package(
    name: "PowerUp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PowerUp",
            dependencies: appDependencies,
            path: "Sources/PowerUp",
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "PowerUpTests",
            dependencies: ["PowerUp"],
            path: "Tests/PowerUpTests"
        )
    ] + coreTargets
)
