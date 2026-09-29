// swift-tools-version:5.9
import PackageDescription

// MackyCore holds all platform-independent logic (request building, stream decoding,
// pointing math, text segmentation). It has no AppKit dependency, so it can be unit
// tested with `swift test` on any machine, including Linux CI.
let package = Package(
    name: "MackyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MackyCore", targets: ["MackyCore"])
    ],
    targets: [
        .target(name: "MackyCore"),
        .testTarget(name: "MackyCoreTests", dependencies: ["MackyCore"])
    ]
)
