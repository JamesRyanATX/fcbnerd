// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "fcbnerd",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fcbnerd", targets: ["fcbnerd"]),
    ],
    targets: [
        // Pure decoding/formatting logic with no CoreMIDI dependency, so it
        // can be unit-tested without hardware.
        .target(name: "FCBNerdCore"),
        // The CLI: CoreMIDI plumbing, argument parsing, simulator.
        .executableTarget(name: "fcbnerd", dependencies: ["FCBNerdCore"]),
        .testTarget(name: "FCBNerdCoreTests", dependencies: ["FCBNerdCore"]),
    ]
)
