// swift-tools-version:6.0
import PackageDescription

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
            dependencies: ["VRMKit", "VRMKitRuntime"],
            exclude: ["Shaders"],
            resources: [.process("Resources")]
        )
    ]
)
