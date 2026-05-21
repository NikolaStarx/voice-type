// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceType", targets: ["VoiceType"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceType",
            path: "Sources/VoiceType",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Speech")
            ]
        )
    ]
)
