// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetalTerrain",
    // macOS for native Mac apps; Catalyst apps build against the iOS SDK.
    // The library is pure Swift + Metal + simd (no UIKit) so it works on both.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MetalTerrain", targets: ["MetalTerrain"]),
    ],
    targets: [
        .target(
            name: "MetalTerrain",
            path: "Sources/MetalTerrain"
        ),
    ]
)
