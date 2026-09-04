// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sidekey",
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
        .executable(name: "Sidekey", targets: ["SidekeyApp"])
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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.14.6")),

        // MLX Swift LM — on-device LLM runtime (MIT) for the local "smart"
        // cleanup + meeting summaries (ROO-257). Provides `MLXLLM` (model
        // factory) and `MLXLMCommon` (`ModelContainer`, `ChatSession`,
        // HuggingFace download via `HubApi`). Pulls in `ml-explore/mlx-swift`
        // (core `MLX`) transitively. Apple Silicon only — gated at the feature
        // level. Pin: 2.31.3 (the 2.x line uses the published
        // huggingface/swift-transformers Hub rather than the 3.x in-tree
        // macro module, keeping the build graph lighter). `.upToNextMinor`
        // mirrors the strict pre-1.0 policy used for FluidAudio/Sparkle.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.31.3"))
    ],
    targets: [
        // App library — all application code. Entry lives in
        // `SidekeyAppMain.run()`.
        .target(
            name: "Sidekey",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ],
            path: "Sources/Sidekey"
        ),
        // The binary users install as Whytap.
        .executableTarget(
            name: "SidekeyApp",
            dependencies: ["Sidekey"],
            path: "Sources/SidekeyApp"
        ),
        // Standalone preview app for iterating on onboarding screens
        // without touching the main Sidekey bundle. Shares the SwiftUI
        // view sources via symlinks (`OnboardingTheme`,
        // `OnboardingWelcomeScreen`, `OnboardingOrbController`,
        // `VoiceOrbView`, `HotkeyHintView`, `KeycapView`) and supplies
        // trivial stubs for the two audio-pipeline singletons that
        // `VoiceOrbView.displayEnergy` reads (`NoiseFloorEstimator`,
        // `AudioEnergyFollower`). No FluidAudio / Sparkle dependencies —
        // runs as a small foreground SwiftUI window.
        .executableTarget(
            name: "OnboardingPreview",
            path: "Sources/OnboardingPreview",
            resources: [
                .copy("Fonts"),
                .copy("Audio"),
                .copy("UsefulLinkIcons")
            ],
            // Lets symlinked screens load bundled brand assets from
            // `Bundle.module` (preview) vs `Bundle.main` (the Sidekey app).
            swiftSettings: [.define("ONBOARDING_PREVIEW")]
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
