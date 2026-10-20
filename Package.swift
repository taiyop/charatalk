// swift-tools-version: 5.9
// Modified for CharaTalk: app-focused package targets and runtime integration.
// Derived from Corvelis/irodori-tts-iphone; see NOTICE and THIRD_PARTY_NOTICES.md.
import PackageDescription

let package = Package(
    name: "IrodoriTTS",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IrodoriTTS", targets: ["IrodoriTTS"]),
    ],
    targets: [
        .target(
            name: "IrodoriTTS",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate")
            ]
        ),
    ]
)
