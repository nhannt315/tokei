// swift-tools-version: 6.0
import PackageDescription

// No test target: the CLT-only toolchain on this machine ships neither XCTest nor
// swift-testing. Core logic is verified by TrackerCoreDemo, an assert-based check
// runner. Run it with `swift run TrackerCoreDemo` (debug only — asserts are
// stripped in release).
let package = Package(
    name: "Tokei",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TrackerCore", resources: [.copy("Resources/DefaultPricing.json")]),
        .executableTarget(name: "Tokei", dependencies: ["TrackerCore"]),
        .executableTarget(name: "TrackerCLI", dependencies: ["TrackerCore"]),
        .executableTarget(name: "TrackerCoreDemo", dependencies: ["TrackerCore"]),
    ]
)
