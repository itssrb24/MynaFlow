// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MynaFlow",
    // macOS 26 is the floor because dictation uses SpeechAnalyzer, the system
    // transcriber, and ships no speech model of its own.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MynaFlowCore", targets: ["MynaFlowCore"]),
        .executable(name: "MynaFlow", targets: ["MynaFlowApp"]),
    ],
    dependencies: [
        // Parakeet v3 ASR (CoreML/ANE). App-target only — MynaFlowCore stays
        // dependency-free so its tests build fast.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .target(
            name: "MynaFlowCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
            ]
        ),
        .target(
            name: "ThinkingOrbsKit",
            // Vendored verbatim from libraries.dev thinking-orbs (MIT, spec 1.0.0
            // · thinking-orbs 0.3.1). Never hand-edit these files: see
            // Sources/ThinkingOrbsKit/UPSTREAM.md before touching anything here.
            exclude: ["LICENSE", "UPSTREAM.md"],
            // Upstream is tools-version 5.9. Pinning v5 keeps these files
            // compiling unchanged across future re-syncs rather than chasing
            // strict-concurrency diagnostics in code we must not edit. They do
            // pass Swift 6 today; this is insurance. MynaFlowApp still gets
            // full checking at the boundary — the public surface is Sendable.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("SwiftUI")]
        ),
        .executableTarget(
            name: "MynaFlowApp",
            dependencies: [
                "MynaFlowCore",
                "ThinkingOrbsKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "MynaFlowCoreTests",
            dependencies: ["MynaFlowCore"]
        ),
        // The re-sync canary: these assert the facts about the vendored orb
        // library that the indicator's reactive drawing depends on.
        .testTarget(
            name: "ThinkingOrbsBridgeTests",
            dependencies: ["ThinkingOrbsKit", "MynaFlowCore"]
        ),
    ]
)
