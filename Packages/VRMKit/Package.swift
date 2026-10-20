// swift-tools-version:6.0
import PackageDescription

// Modified for CharaTalk: remove unused MToon shaders and precompiled resources.
// The VRM/glTF material data and built-in Unlit/PBR renderer are retained.

let package = Package(
    name: "VRMKit",
    platforms: [.iOS(.v15), .macOS(.v12), .watchOS(.v8), .visionOS(.v2)],
    products: [
        .library(name: "VRMKit", targets: ["VRMKit"]),
        .library(name: "VRMRealityKit", targets: ["VRMRealityKit"])
    ],
    targets: [
        .target(
            name: "VRMKit",
            exclude: ["Extensions/MoreCodable/LICENSE"]
        ),
        .target(
            name: "VRMKitRuntime",
            dependencies: ["VRMKit"]
        ),
        .target(
            name: "VRMRealityKit",
            dependencies: ["VRMKit", "VRMKitRuntime"]
        )
    ]
)
