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
            name: "IrodoriNative",
            publicHeadersPath: "include",
            cxxSettings: [.define("IRODORI_COREML_ONLY", to: "1")],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "IrodoriTTS",
            dependencies: ["IrodoriNative"],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
