// swift-tools-version: 6.2
import PackageDescription

// Part 2 §1: SPM package (pure, testable) + a thin Xcode app target that holds
// everything OS-dependent. Part 2 §4: Swift 6 strict concurrency on, and a
// Sendable warning is a design bug to fix rather than something to silence.
let package = Package(
    name: "ChalantDictationCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ChalantDictationCore", targets: ["ChalantDictationCore"])
    ],
    targets: [
        .target(
            name: "ChalantDictationCore",
            swiftSettings: [
                // Part 2 §2: Core knows only Foundation. Nothing here may import
                // AppKit, AVFoundation or ApplicationServices.
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ChalantDictationCoreTests",
            dependencies: ["ChalantDictationCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
