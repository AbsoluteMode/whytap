// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Whytap",
    // macOS 14.2 (Sonoma) is the deployment floor — matches
    // `LSMinimumSystemVersion` in `Resources/Info.plist.template`. 14.2
    // (not 14.0) because Meeting Notes' system-audio capture uses the
    // CoreAudio process-tap API (`AudioHardwareCreateProcessTap`,
    // introduced in macOS 14.2). The voice/agent orb is `BlobShape` (a
    // custom SwiftUI `Shape`), not the macOS 15 `MeshGradient` an earlier
    // iteration used, so the render path no longer pins us to macOS 15.
    // Any newer-SDK call is guarded by `if #available`; the Swift
    // availability checker enforces that against the deployment target.
    platforms: [.macOS("14.2")],
    products: [
        // One app library ("Sidekey", module name unchanged so the test
        // target and its hundreds of `@testable import Sidekey` files stay
        // untouched) plus a thin executable shim. NB: the built binary is
        // `.build/<config>/SidekeyApp` (SwiftPM names binaries after the
        // target); `build-dmg.sh` renames it to `Sidekey` when assembling
        // the .app so `CFBundleExecutable` stays stable.
        .executable(name: "Sidekey", targets: ["SidekeyApp"]),
        // Command-line helper for the Case secrets manager. Depends only on
        // WhytapCaseKit (never on Sidekey) so it stays small.
        .executable(name: "whytap", targets: ["WhytapCLI"])
    ],
    dependencies: [
        // Sparkle 2 — auto-update framework.
        // 2.9.x is the current stable line (latest at pin time: 2.9.1, March 2026).
        // .upToNextMinor pins minor (no major bumps without explicit review)
        // while still letting Dependabot bring in patch fixes.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMinor(from: "2.9.1")),

        // FluidAudio — Silero VAD (Apache-2.0) running on the Apple Neural
        // Engine. Used by Stage 2's `SystemAudioVADProbe` to detect speech
        // in the explicit meeting-recording audio stream. Picked over
        // Apple's `SpeechDetector` because the latter requires macOS 26
        // (Tahoe) and Sidekey's deployment floor is macOS 14.
        // Pin: 0.14.6 (released 2026-05-17, the latest stable tag at the
        // time Stage 1a landed; verified via GitHub Releases API).
        // `.upToNextMinor` is intentionally strict — FluidAudio is still
        // pre-1.0 so we treat minor bumps as breaking and gate them on
        // an explicit review.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.14.6"))
    ],
    targets: [
        // App library — all application code. Entry lives in
        // `SidekeyAppMain.run()`.
        // Shared protocol + masker for the app and the `whytap` CLI.
        // Must not depend on Sidekey.
        .target(
            name: "WhytapCaseKit",
            path: "Sources/WhytapCaseKit"
        ),
        // sherpa-onnx keyword spotter (Apache-2.0) for the opt-in wake word,
        // with the ONNX Runtime it links (MIT). Official prebuilt static
        // universal (arm64 + x86_64) xcframeworks, pinned by checksum. Declared
        // as binary targets here because the upstream package's Swift target
        // would clone the whole sherpa-onnx repository; WakeWord/ wraps the C
        // API itself. sherpa-onnx v2.0.1 expects ONNX Runtime 1.28.2.
        // WHY: .project-docs/decisions/2026-11-11-wake-word.md
        .binaryTarget(
            name: "SherpaOnnxC",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.1-macos-static.xcframework.zip",
            checksum: "3c378789ebcbf3b1fb2e7cf0c58dae8e5629001598148aee2edd4494dc939a27"
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip",
            checksum: "cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0"
        ),
        .target(
            name: "Sidekey",
            dependencies: [
                "WhytapCaseKit",
                "SherpaOnnxC",
                "onnxruntime",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Sidekey",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // The binary users install as Whytap.
        .executableTarget(
            name: "SidekeyApp",
            dependencies: ["Sidekey"],
            path: "Sources/SidekeyApp"
        ),
        .executableTarget(
            name: "WhytapCLI",
            dependencies: ["WhytapCaseKit"],
            path: "Sources/WhytapCLI"
        ),
        .testTarget(
            name: "WhytapCaseKitTests",
            dependencies: ["WhytapCaseKit"],
            path: "Tests/WhytapCaseKitTests"
        ),
        .testTarget(
            name: "SidekeyTests",
            dependencies: ["Sidekey"],
            path: "Tests/SidekeyTests"
        )
    ],
    // Pin the package to Swift 5 language mode. The swift-tools-version 6.0
    // manifest is what enables the `swiftLanguageModes:` parameter below;
    // without it the package would default to Swift 6 and turn the existing
    // codebase's actor-isolation patterns into hard errors. A separate task
    // can opt the package into Swift 6 mode after the actor boundaries get
    // audited.
    swiftLanguageModes: [.v5]
)
