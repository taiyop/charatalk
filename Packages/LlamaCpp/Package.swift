// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LlamaCpp", targets: ["LlamaCpp"])
    ],
    dependencies: [
        .package(name: "IrodoriTTS", path: "../..")
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            path: "Artifacts/llama.xcframework.zip"
        ),
        .target(
            name: "LlamaCppNative",
            dependencies: ["llama"],
            sources: ["LlamaCppBridge.mm"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "LlamaCpp",
            dependencies: [
                "LlamaCppNative",
                .product(name: "IrodoriTTS", package: "IrodoriTTS")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
