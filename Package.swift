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
        .executableTarget(
            name: "MynaFlowApp",
            dependencies: [
                "MynaFlowCore",
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
    ]
)
