// swift-tools-version: 6.2
// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

import PackageDescription

let package = Package(
    name: "spfk-audio-nodes",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(
            name: "SPFKAudioNodes",
            targets: ["SPFKAudioNodes", "SPFKAudioNodesC"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ryanfrancesconi/spfk-audio-base", from: "0.0.6"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-au-host", from: "0.0.7"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-utils", from: "0.0.8"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-testing", from: "0.0.1"),
    ],
    targets: [
        .target(
            name: "SPFKAudioNodes",
            dependencies: [
                .product(name: "SPFKAudioBase", package: "spfk-audio-base"),
                .product(name: "SPFKAUHost", package: "spfk-au-host"),
                .product(name: "SPFKUtils", package: "spfk-utils"),
                .targetItem(name: "SPFKAudioNodesC", condition: nil),
            ],
            resources: [
                .copy("Resources/Metronome"),
            ]
        ),
        .target(
            name: "SPFKAudioNodesC",
            dependencies: [],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include_private"),
            ],
            cxxSettings: [
                .headerSearchPath("include_private"),
            ]
        ),
        .testTarget(
            name: "SPFKAudioNodesTests",
            dependencies: [
                .targetItem(name: "SPFKAudioNodes", condition: nil),
                .targetItem(name: "SPFKAudioNodesC", condition: nil),
                .product(name: "SPFKTesting", package: "spfk-testing"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
