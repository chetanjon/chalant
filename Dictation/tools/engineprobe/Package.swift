// swift-tools-version: 6.2
import PackageDescription

// **Its own package, and the reason is the Core test loop.** Adding FluidAudio
// and WhisperKit to `Dictation/Package.swift` would make every `swift test` in
// Dictation/ resolve and link two speech frameworks, which turns the fastest
// feedback loop in the project into the slowest. The library target also has a
// standing rule that Core imports only Foundation, and a sibling executable
// depending on a CoreML framework is a confusing thing to have in the same
// manifest even when it is technically allowed.
//
// Pinned exactly, matching `project.yml`. A probe measuring a different build
// of the engine than the app ships is a probe that measures nothing.
let package = Package(
    name: "engineprobe",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "engineprobe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "ChalantDictationCore", package: "Dictation"),
            ]
        )
    ]
)
