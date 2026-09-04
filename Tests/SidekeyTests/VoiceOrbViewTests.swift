import SwiftUI
import XCTest
@testable import Sidekey

final class VoiceOrbViewTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        // Reset singletons that other test files can leave in a non-default
        // state (the orb's audio path reads from these shared instances).
        NoiseFloorEstimator.shared.reset()
        AudioEnergyFollower.shared.reset()
    }

    // MARK: - Multi-ring BlobShape composition (Siri-style orb pivot)

    /// Architectural anti-regression: `activeOrb` must compose a stack of
    /// `BlobShape` strokes (the harmonic sum-of-sines wobble shape) — the
    /// "Siri orb" concept. NOT a filled `MeshGradient` sphere, NOT a
    /// single thin ring.
    ///
    /// History timeline:
    ///   1. Metal `.colorEffect` shader (retired)
    ///   2. `MeshGradient` filled sphere + color blobs (retired)
    ///   3. Single `DeformedRing` stroke (retired — too "loop", not enough volume)
    ///   4. **BlobShape multi-ring stack** (current) — irregular wobbling
    ///      polygon based on a harmonic sum-of-sines, layered for outer
    ///      bloom + 7 concentric strokes + black core, audio-reactive
    ///      through `audioLevel` baked into each `BlobShape`.
    ///
    /// Any future change that re-introduces `MeshGradient` as the
    /// active-orb base fill, or removes `BlobShape`, fails this test.
    func testActiveOrbUsesBlobShapeStack() throws {
        let source = try loadVoiceOrbSource()
        let activeOrbBody = try extractFunctionBody(source: source, header: "private func activeOrb(")

        XCTAssertTrue(
            activeOrbBody.contains("BlobShape("),
            "activeOrb must compose at least one BlobShape — the harmonic sum-of-sines shape is the visual heart of the orb. Body:\n\(activeOrbBody)"
        )

        // Older concepts must not coexist in the active orb body.
        XCTAssertFalse(
            activeOrbBody.contains("MeshGradient("),
            "MeshGradient belonged to the filled-mesh era and must not return inside activeOrb."
        )
        XCTAssertFalse(
            activeOrbBody.contains("ShaderLibrary"),
            "ShaderLibrary belonged to the Metal-shader era — gone for good."
        )
        XCTAssertFalse(
            activeOrbBody.contains(".colorEffect("),
            ".colorEffect was the Metal shader entry point — gone for good."
        )
        XCTAssertFalse(
            activeOrbBody.contains("DeformedRing("),
            "DeformedRing belonged to the single-stroke ring era — replaced by the BlobShape multi-ring stack."
        )
    }

    /// Anti-regression: the active orb must NOT use the `.shadow(...)`
    /// modifier on the composited orb body. `.shadow` draws from the
    /// bounding rect of the view it modifies; with large blurs present
    /// the shadow's effective rectangle extends past the circular shape
    /// and surfaces as a square halo around the orb. Use multi-layer
    /// stroked rings with `.plusLighter` / `.screen` blend instead.
    func testActiveOrbHasNoShadowModifier() throws {
        let source = try loadVoiceOrbSource()
        let activeOrbBody = try extractFunctionBody(source: source, header: "private func activeOrb(")

        XCTAssertFalse(
            activeOrbBody.contains(".shadow("),
            ".shadow modifier on the composited active orb produces a square halo when active — use stroked + blurred ring layers for bloom instead. Body:\n\(activeOrbBody)"
        )
    }

    /// Anti-regression for the "rough circle outline" Maxim flagged in
    /// visual review: the outer composited orb stack must NOT be
    /// hard-clipped by a plain `Circle()` mask. A hard circle mask
    /// produces a visible sharp edge around the bloom. Use a
    /// `RadialGradient`-based mask that fades to alpha 0 at the edge so
    /// the bloom dissolves smoothly, OR omit the mask entirely (the
    /// floating panel frame already clips anything past `canvasSize`).
    func testOrbBodyHasNoHardCircleMask() throws {
        let source = try loadVoiceOrbSource()
        let bodyBody = try extractFunctionBody(source: source, header: "var body: some View")

        XCTAssertFalse(
            bodyBody.contains(".mask(Circle()"),
            "Hard `.mask(Circle())` on the orb body produces a visible sharp circle edge around the bloom. Use a radial-fade mask (`Circle().fill(RadialGradient(...))`) or drop the mask entirely. Body:\n\(bodyBody)"
        )
        XCTAssertFalse(
            bodyBody.contains(".clipShape(Circle()"),
            "Hard `.clipShape(Circle())` causes the same sharp edge as `.mask(Circle())`. Use a radial-fade mask instead. Body:\n\(bodyBody)"
        )
    }

    /// The BlobShape Shape type must be defined and animatable so the
    /// SwiftUI animation engine can interpolate its `phase`/`audioLevel`
    /// between frames. Pinning `animatableData` catches a regression
    /// to a static, non-interpolating Shape — which would freeze the
    /// orb visually even though `TimelineView` keeps ticking.
    func testBlobShapeIsDefinedAndAnimatable() throws {
        let source = try loadVoiceOrbSource()
        XCTAssertTrue(
            source.contains("struct BlobShape"),
            "BlobShape Shape type must be defined — it's the harmonic sum-of-sines shape under every ring."
        )
        XCTAssertTrue(
            source.contains("animatableData"),
            "BlobShape must expose animatableData so SwiftUI can interpolate phase / audioLevel between frames."
        )
        XCTAssertTrue(
            source.contains("HarmonicSet"),
            "BlobShape must drive its radius wobble from a HarmonicSet — the multiple sets (primary/secondary/tertiary/quaternary) give each layer a distinct rhythm."
        )
    }

    /// Obsolete helpers from previous pivots must be removed. Keeping
    /// `colorBlobs`, `chromaticRim`, etc. as dead code pollutes the
    /// file and confuses future readers about which concept is active.
    func testObsoleteHelpersAreRemoved() throws {
        let source = try loadVoiceOrbSource()
        let banned = [
            "colorBlobs(",
            "BlobConfig",
            "chromaticRim(",
            "meshControlPoints(",
            "meshPalette",
            "struct DeformedRing"
        ]
        for needle in banned {
            XCTAssertFalse(
                source.contains(needle),
                "`\(needle)` belongs to a previous pivot and must be removed."
            )
        }
    }

    // MARK: - Source loading helpers

    private func loadVoiceOrbSource() throws -> String {
        let candidates = candidateSourceURLs(for: "VoiceOrbView.swift")
        for url in candidates {
            if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        throw XCTSkip("VoiceOrbView.swift source not reachable from test bundle — tried: \(candidates.map(\.path).joined(separator: ", "))")
    }

    private func candidateSourceURLs(for filename: String) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        if let srcroot = env["SRCROOT"] { roots.append(URL(fileURLWithPath: srcroot)) }
        if let pkgRoot = env["PACKAGE_PATH"] { roots.append(URL(fileURLWithPath: pkgRoot)) }

        // Walk up from this test file to find the package root (where Package.swift lives).
        let thisFile = URL(fileURLWithPath: #filePath)
        var cursor = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
                roots.append(cursor)
                break
            }
            cursor = cursor.deletingLastPathComponent()
        }
        return roots.map { $0.appendingPathComponent("Sources/Sidekey/\(filename)") }
    }

    private func extractFunctionBody(source: String, header: String) throws -> String {
        guard let start = source.range(of: header) else {
            throw XCTSkip("Function header not found: \(header)")
        }
        // Find first '{' after the header, then track brace depth.
        guard let openBrace = source.range(of: "{", range: start.upperBound..<source.endIndex) else {
            throw XCTSkip("No opening brace after \(header)")
        }
        var depth = 1
        var idx = openBrace.upperBound
        while idx < source.endIndex && depth > 0 {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        return String(source[openBrace.upperBound..<idx])
    }

    // MARK: - Energy math

    func testAudioEnergyReturnsLastRawLevel() {
        // `audioEnergy` is now the raw most-recent sample. Smoothing has
        // moved to `AudioEnergyFollower` so pauses register instantly.
        let energy = VoiceOrbView.audioEnergy(levels: [0.1, 0.3, 0.5])

        XCTAssertEqual(energy, 0.5, accuracy: 0.001)
    }

    func testAudioEnergyClampsAboveOne() {
        let energy = VoiceOrbView.audioEnergy(levels: [1.2, 1.4])

        XCTAssertEqual(energy, 1.0, accuracy: 0.001)
    }

    func testIdleDisplayEnergyIsStatic() {
        XCTAssertEqual(
            VoiceOrbView.displayEnergy(levels: [0.9], time: 1.0, mode: .idle),
            0
        )
    }

    func testVoiceDrivenModeIsStaticBeforeMeterSamples() {
        XCTAssertEqual(
            VoiceOrbView.displayEnergy(levels: [], time: 0.0, mode: .dropVoice),
            0
        )
    }

    func testVoiceDrivenModeIsStaticForZeroAudio() {
        XCTAssertEqual(
            VoiceOrbView.displayEnergy(levels: [0, 0, 0], time: 10.0, mode: .dropVoice),
            0
        )
    }

    func testVoiceDrivenModeIsStaticBelowNoiseGate() {
        // Levels averaging well below voiceNoiseGate (0.04) — room tone
        // / mic hiss should not move the orb.
        XCTAssertEqual(
            VoiceOrbView.displayEnergy(levels: [0.005, 0.01, 0.02], time: 10.0, mode: .dropVoice),
            0
        )
    }

    func testVoiceDrivenModeRespondsToAudio() {
        XCTAssertGreaterThan(
            VoiceOrbView.displayEnergy(levels: [0.50], time: 10.0, mode: .dropVoice),
            0
        )
    }

    func testGoogleVoiceUsesReactiveProfileLikeOtherVoiceModes() {
        // Regression: .googleVoice fell through stateProfile's `default` (all
        // gains 0), so the orb appeared but sat motionless — no reaction to
        // voice. It must share the reactive listening profile with drop/agent.
        let google = VoiceOrbView.stateProfile(for: .googleVoice)
        let agent = VoiceOrbView.stateProfile(for: .agentVoice)
        XCTAssertEqual(google.audioGain, agent.audioGain)
        XCTAssertEqual(google.speedGain, agent.speedGain)
        XCTAssertEqual(google.tempo, agent.tempo)
        XCTAssertGreaterThan(google.speedGain, 0,
            "google voice orb must react to audio, not sit in the dead default profile")
    }

    func testAgentProcessingIsActiveWithoutAudio() {
        XCTAssertGreaterThan(
            VoiceOrbView.displayEnergy(levels: [], time: 0.0, mode: .agentProcessing),
            0
        )
    }

    // MARK: - Sizing (25pt orb, 16pt glow, 57pt canvas — post glow-padding bump)

    /// Orb diameter after the 30% vertical shrink (36pt → 25pt, rounded to
    /// nearest 1pt). The orb is a `Circle`, so its height = diameter and
    /// shrinking the height side-effects the width too — accepted because
    /// the orb-cluster is anchored bottom-right and a round shape can't
    /// shrink one axis without the other.
    ///
    /// The glow-padding bump (`glowMargin` 8 → 16) deliberately leaves
    /// `orbSize` untouched so the visible orb stays the same size —
    /// only the transparent canvas around it grew.
    func testOrbSizeMatchesProductSize() {
        XCTAssertEqual(VoiceOrbView.orbSize, 25)
    }

    /// Glow margin was 8pt post-30%-shrink (PR #123). Build 1107
    /// surfaced a «квадратная рамка вокруг round white orb» regression:
    /// with only 8pt of margin the soft-halo radial mask reached alpha
    /// 0 right at the canvas-edge midpoint, but the canvas corners
    /// (~1.41× past that radius) sat past the gradient and the residual
    /// bloom alpha bled into them. Bumping the glow margin to 16pt
    /// gives the mask comfortable room past the bloom's natural extent
    /// (≈ orbSize = 25pt) so the corner pixels reliably hit alpha 0.
    func testGlowMarginMatchesProductMargin() {
        XCTAssertEqual(VoiceOrbView.glowMargin, 16)
    }

    /// Canvas = orbSize (25) + 2 × glowMargin (16) = 57pt. After the
    /// glow-padding bump (was 41pt with 8pt margin). The identity
    /// `canvasSize = orbSize + 2*glowMargin` is the load-bearing
    /// relationship the soft-halo mask + bloom math rely on; pin both
    /// the formula AND the concrete pt size so a regression of either
    /// (constant drift, formula drift) is caught immediately.
    func testCanvasSizeIsOrbPlusTwoGlowMargins() {
        XCTAssertEqual(
            VoiceOrbView.canvasSize,
            VoiceOrbView.orbSize + VoiceOrbView.glowMargin * 2
        )
        XCTAssertEqual(VoiceOrbView.canvasSize, 57)
    }

    /// Regression guard for the 30% vertical-shrink directive: the
    /// **visible orb** (not the transparent canvas around it) must
    /// remain ≈70% of the pre-shrink 36pt value. Tolerance is loose
    /// (within 2pt of the exact 25pt target) so per-component rounding
    /// is allowed while a future drift back toward the pre-shrink size
    /// or further down is caught immediately.
    ///
    /// **Was pinned to `canvasSize`** before the glow-padding bump
    /// (canvasSize is now bigger than pre-shrink so the old assertion
    /// no longer expresses the shrink). Switching to `orbSize` captures
    /// the actual visible shrink the user sees.
    func testOrbSizeIsRoughly70PercentOfPreShrinkValue() {
        let preShrink: CGFloat = 36
        let target = preShrink * 0.7
        XCTAssertEqual(VoiceOrbView.orbSize, target, accuracy: 2.0)
    }

    /// Anti-regression for the «квадратная рамка вокруг round white orb»
    /// class of bugs (build 1107): the canvas half-side must sit
    /// comfortably past the bloom's natural endRadius so the soft-halo
    /// radial mask's fade-to-zero reaches the canvas corners before the
    /// bloom gradient still has residual alpha there. The bloom in
    /// `activeOrb` uses `endRadius: baseR * 2.0` where `baseR ≈
    /// orbSize/2`, so the bloom's natural fade-to-zero radius is
    /// approximately `orbSize`. Requiring `canvasSize / 2 > orbSize`
    /// ensures the mask's `endRadius` (= canvasSize/2) sits past the
    /// bloom's natural extent — the corners (at sqrt(2) × canvasSize/2
    /// ≈ 1.41 × half-side) fall well past the fade ring, so the visible
    /// edge of the panel is round, not square.
    func testCanvasHalfSideExceedsGlowNaturalExtent() {
        XCTAssertGreaterThan(
            VoiceOrbView.canvasSize / 2,
            VoiceOrbView.orbSize,
            "Canvas half-side must exceed the bloom's natural endRadius (≈ orbSize) so the soft-halo mask catches the fade-to-zero with buffer at the corners."
        )
    }

    // MARK: - Composition invariants (mutual exclusion of ring vs active orb)

    func testIdleModeRendersOnlyTheRing() {
        XCTAssertEqual(VoiceOrbView.composition(for: .idle), .ring)
    }

    func testDropVoiceRendersOnlyTheActiveOrb() {
        XCTAssertEqual(VoiceOrbView.composition(for: .dropVoice), .activeOrb)
    }

    func testDropProcessingRendersOnlyTheActiveOrb() {
        XCTAssertEqual(VoiceOrbView.composition(for: .dropProcessing), .activeOrb)
    }

    func testAgentVoiceRendersOnlyTheActiveOrb() {
        XCTAssertEqual(VoiceOrbView.composition(for: .agentVoice), .activeOrb)
    }

    func testAgentProcessingRendersOnlyTheActiveOrb() {
        XCTAssertEqual(VoiceOrbView.composition(for: .agentProcessing), .activeOrb)
    }

    func testAgentTextInputActiveRendersGradientRing() {
        XCTAssertEqual(
            VoiceOrbView.composition(for: .agentTextInputActive),
            .gradientRing
        )
    }

    // MARK: - Mode flags for the gradient-ring mode

    func testAgentTextInputActiveCountsAsActive() {
        XCTAssertTrue(VoiceOrbMode.agentTextInputActive.isActive)
    }

    func testAgentTextInputActiveIsNotVoiceDriven() {
        XCTAssertFalse(VoiceOrbMode.agentTextInputActive.isVoiceDriven)
    }

    func testAgentTextInputActiveIsAgentMode() {
        XCTAssertTrue(VoiceOrbMode.agentTextInputActive.isAgent)
    }

    // MARK: - Adaptive palette (drop) vs fixed palette (agent)

    /// Drop flow (voice / processing without agent) must adapt to the
    /// background: a dark wallpaper produces a white orb, a light
    /// wallpaper produces a black one. The `OrbPaletteFlavor` selector
    /// is the public hand-off between `BackgroundLuminanceObserver` and
    /// the orb's palette.
    func testDropVoicePaletteIsWhiteOnDarkBackground() {
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .dropVoice, isDarkBackground: true),
            .adaptiveWhite
        )
    }

    func testDropVoicePaletteIsBlackOnLightBackground() {
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .dropVoice, isDarkBackground: false),
            .adaptiveBlack
        )
    }

    func testDropProcessingPaletteIsAdaptive() {
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .dropProcessing, isDarkBackground: true),
            .adaptiveWhite
        )
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .dropProcessing, isDarkBackground: false),
            .adaptiveBlack
        )
    }

    /// Agent flow always renders the pink-violet gradient: the user
    /// taught the gesture as "the AI agent flavor" so it must read the
    /// same regardless of background. Switching backgrounds during an
    /// agent session must NOT recolor the orb.
    func testAgentVoiceUsesFixedPinkVioletPaletteRegardlessOfBackground() {
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .agentVoice, isDarkBackground: true),
            .pinkViolet
        )
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .agentVoice, isDarkBackground: false),
            .pinkViolet
        )
    }

    func testAgentProcessingUsesFixedPinkVioletPalette() {
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .agentProcessing, isDarkBackground: true),
            .pinkViolet
        )
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .agentProcessing, isDarkBackground: false),
            .pinkViolet
        )
    }

    func testAgentTextInputActiveUsesFixedPinkVioletPalette() {
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .agentTextInputActive, isDarkBackground: true),
            .pinkViolet
        )
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .agentTextInputActive, isDarkBackground: false),
            .pinkViolet
        )
    }

    // MARK: - State profile floors (anti-regression on visual tuning)

    /// Listening keeps amplitude calm (baseline 1.0) — Maxim explicitly
    /// said decibels should drive the SPEED of harmonic motion, not the
    /// SIZE of the wobble. The amplitude floor protects against the
    /// previous "inflate the rings on loud audio" interpretation.
    func testListeningProfileWobbleGainStaysAtBaseline() {
        let p = VoiceOrbView.stateProfile(for: .dropVoice)
        XCTAssertEqual(
            p.wobbleGain, 1.0, accuracy: 0.1,
            "Listening wobble amplitude must stay at baseline (~1.0) — audio drives SPEED, not amplitude."
        )
    }

    /// Listening's `audioGain` (audio → working level inside the orb)
    /// stays at baseline. The amplitude pipeline should not balloon
    /// with audio; the speed pipeline does.
    func testListeningProfileAudioGainStaysAtBaseline() {
        let p = VoiceOrbView.stateProfile(for: .dropVoice)
        XCTAssertEqual(
            p.audioGain, 1.0, accuracy: 0.1,
            "Listening audioGain must not amplify mic energy into the amplitude pipeline — audio drives SPEED, not size."
        )
    }

    /// `speedGain` is the per-profile knob that turns mic energy into
    /// phase-acceleration. Listening should move with speech without
    /// becoming chaotic. The previous round (`Codex`) clamped it to
    /// `0.45` together with a hard-freeze at zero — fixing that freeze
    /// requires letting speedGain go back to a sensible audible level.
    func testListeningProfileSpeedGainIsAudible() {
        let p = VoiceOrbView.stateProfile(for: .dropVoice)
        XCTAssertGreaterThanOrEqual(
            p.speedGain, 1.0,
            "Listening speedGain must be high enough that real speech visibly accelerates the rings."
        )
        XCTAssertLessThanOrEqual(
            p.speedGain, 12.0,
            "Listening speedGain must stay below the chaotic-buzz ceiling."
        )
    }

    /// Thinking has no audio input, so `speedGain` is 0. Motion comes
    /// from `spin`, not from audio.
    func testThinkingProfileSpeedGainIsZero() {
        let p = VoiceOrbView.stateProfile(for: .dropProcessing)
        XCTAssertEqual(
            p.speedGain, 0, accuracy: 0.001,
            "Thinking has no audio input — speedGain must be 0 (motion comes from spin, not from audio)."
        )
    }

    /// Listening keeps a small free-flowing sway so the orb reads as
    /// alive at idle too. Lower bound only — Codex's previous 0.045
    /// was too small (orb felt frozen) and 0.5+ was too wobbly.
    func testListeningProfileFreedomStaysOn() {
        let p = VoiceOrbView.stateProfile(for: .dropVoice)
        XCTAssertGreaterThanOrEqual(
            p.freedom, 0.1,
            "Listening freedom must stay on (~0.2) so the rings are visibly alive even at silence."
        )
    }

    /// Listening tempo must keep the master phase moving continuously
    /// at silence — too low and the orb looks frozen between words.
    /// Codex's previous 0.70 paired with a hard freeze read as stuck;
    /// the floor here is ~1.0.
    func testListeningProfileTempoMovesAtSilence() {
        let p = VoiceOrbView.stateProfile(for: .dropVoice)
        XCTAssertGreaterThanOrEqual(
            p.tempo, 0.9,
            "Listening tempo must be high enough that the orb visibly moves at silence."
        )
    }

    /// Maxim asked for noticeably faster rigid-body rotation while
    /// processing. Pin a floor at `0.7` rad/sec so any "slow it down"
    /// regression trips this test.
    func testThinkingProfileSpinExceedsFloor() {
        let p = VoiceOrbView.stateProfile(for: .dropProcessing)
        XCTAssertGreaterThanOrEqual(
            p.spin, 0.7,
            "Thinking rigid-body spin must read as 'actively processing' — regressed below the visual floor."
        )
    }

    /// Drop and agent voice modes share the listening profile.
    func testAgentVoiceUsesSameListeningProfileAsDropVoice() {
        let drop = VoiceOrbView.stateProfile(for: .dropVoice)
        let agent = VoiceOrbView.stateProfile(for: .agentVoice)
        XCTAssertEqual(drop.wobbleGain, agent.wobbleGain, accuracy: 0.001)
        XCTAssertEqual(drop.audioGain, agent.audioGain, accuracy: 0.001)
        XCTAssertEqual(drop.speedGain, agent.speedGain, accuracy: 0.001)
        XCTAssertEqual(drop.freedom, agent.freedom, accuracy: 0.001)
        XCTAssertEqual(drop.spin, agent.spin, accuracy: 0.001)
    }

    /// Drop and agent processing modes share the thinking profile.
    func testAgentProcessingUsesSameThinkingProfileAsDropProcessing() {
        let drop = VoiceOrbView.stateProfile(for: .dropProcessing)
        let agent = VoiceOrbView.stateProfile(for: .agentProcessing)
        XCTAssertEqual(drop.spin, agent.spin, accuracy: 0.001)
        XCTAssertEqual(drop.wobbleGain, agent.wobbleGain, accuracy: 0.001)
        XCTAssertEqual(drop.speedGain, agent.speedGain, accuracy: 0.001)
    }

    // MARK: - BlobShape: smooth audio envelope

    /// Audio is allowed to modulate harmonic deformation, but the final
    /// radius expression must remain clean: no direct `baseR * audio`
    /// multiplier that would balloon the whole orb.
    func testBlobShapePathDoesNotInflateRadiusWithAudio() throws {
        let source = try loadVoiceOrbSource()
        let body = try extractFunctionBody(source: source, header: "func path(in rect: CGRect) -> Path")

        // Find the radius computation line — `let r = baseR * (...)`.
        // The substring after `let r = baseR *` and before the next
        // newline is the only place we care about; doc-comments don't
        // start with `let r = `.
        guard let rRange = body.range(of: "let r = baseR *") else {
            return XCTFail("Could not find the radius computation line — has BlobShape.path(in:) been refactored?")
        }
        let lineEnd = body[rRange.upperBound...].firstIndex(of: "\n") ?? body.endIndex
        let rExpression = String(body[rRange.upperBound..<lineEnd])

        XCTAssertFalse(
            rExpression.contains("audioLevel"),
            "BlobShape radius expression must not reference `audioLevel` directly — audio drives phase SPEED, not radius. Expression: `\(rExpression)`"
        )
    }

    /// Functional check: at the same `phase`, two BlobShapes with
    /// different `audioLevel` values must produce different paths when
    /// `speedGain > 0` (which is how the active orb wires it). Confirms
    /// audio reaches the harmonic envelope.
    func testBlobShapePathChangesWhenAudioLevelDiffersAtSpeedGain() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        let quiet = BlobShape(
            phase: 1.0,
            seedOffset: 0.3,
            audioLevel: 0.0,
            harmonics: .primary,
            freedom: 0,
            speedGain: 2.5
        )
        let loud = BlobShape(
            phase: 1.0,
            seedOffset: 0.3,
            audioLevel: 1.0,
            harmonics: .primary,
            freedom: 0,
            speedGain: 2.5
        )

        let quietPoints = quiet.path(in: rect).samplePoints(steps: 32)
        let loudPoints = loud.path(in: rect).samplePoints(steps: 32)

        XCTAssertNotEqual(
            quietPoints, loudPoints,
            "With speedGain > 0, audio must change the harmonic envelope. Audio is being ignored."
        )
    }

    /// At zero audio in a voice mode (`speedGain > 0`), the orb is a
    /// geometric circle — no wobble, no sway — regardless of timeline
    /// phase. Audio drives both deformation gain and sway amplitude,
    /// so silence pins them to zero. Maxim explicitly asked: «wobble
    /// должен увеличиваться только на бусте».
    func testBlobShapePathIsStaticCircleAtZeroAudioInVoiceMode() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        let frameA = BlobShape(
            phase: 1.0,
            seedOffset: 0.3,
            audioLevel: 0.0,
            harmonics: .primary,
            freedom: 0.2,
            speedGain: 1.5
        )
        let frameB = BlobShape(
            phase: 9.0,
            seedOffset: 0.3,
            audioLevel: 0.0,
            harmonics: .primary,
            freedom: 0.2,
            speedGain: 1.5
        )

        XCTAssertEqual(
            frameA.path(in: rect).samplePoints(steps: 32),
            frameB.path(in: rect).samplePoints(steps: 32),
            "Voice-mode silence must render an identical static circle regardless of timeline phase — wobble and sway are audio-gated."
        )
    }

    /// Continuity at the noise-gate threshold: BlobShape's rendered
    /// path must change continuously as audio crosses `silenceEnergyThreshold`.
    /// Two infinitesimally-close audio levels (just below + just above
    /// the threshold) must produce paths that are close in Manhattan
    /// distance — NOT teleport between "phase = 0" and "phase = real".
    /// This is the direct anti-regression on Codex's freeze.
    func testBlobShapePathIsContinuousAtSilenceThreshold() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        let threshold = Double(VoiceOrbView.silenceEnergyThreshold)
        // Bracket the threshold from both sides. The deltas are tiny
        // (10^-6) so any discontinuity at the boundary shows up as a
        // large path delta.
        let justBelow = BlobShape(
            phase: 5.0,
            seedOffset: 0.3,
            audioLevel: max(0, threshold - 1e-6),
            harmonics: .primary,
            freedom: 0.2,
            speedGain: 1.5
        )
        let justAbove = BlobShape(
            phase: 5.0,
            seedOffset: 0.3,
            audioLevel: threshold + 1e-6,
            harmonics: .primary,
            freedom: 0.2,
            speedGain: 1.5
        )

        let pointsBelow = justBelow.path(in: rect).samplePoints(steps: 32)
        let pointsAbove = justAbove.path(in: rect).samplePoints(steps: 32)
        XCTAssertEqual(pointsBelow.count, pointsAbove.count)

        let maxDelta = zip(pointsBelow, pointsAbove)
            .map { abs($0.x - $1.x) + abs($0.y - $1.y) }
            .max() ?? 0
        XCTAssertLessThan(
            maxDelta, 1.0,
            "BlobShape rendered path must change CONTINUOUSLY across the silence threshold. A spike of \(maxDelta)pt means there's a discontinuity (freeze-at-threshold)."
        )
    }

    /// And the inverse: with `speedGain = 0` (thinking profile, idle,
    /// or any layer that opts out), audio MUST have no effect on the
    /// rendered path.
    func testBlobShapePathIsAudioInvariantWhenSpeedGainIsZero() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        let quiet = BlobShape(
            phase: 1.0,
            seedOffset: 0.3,
            audioLevel: 0.0,
            harmonics: .primary,
            freedom: 0,
            speedGain: 0
        )
        let loud = BlobShape(
            phase: 1.0,
            seedOffset: 0.3,
            audioLevel: 1.0,
            harmonics: .primary,
            freedom: 0,
            speedGain: 0
        )

        let quietPoints = quiet.path(in: rect).samplePoints(steps: 32)
        let loudPoints = loud.path(in: rect).samplePoints(steps: 32)

        XCTAssertEqual(
            quietPoints, loudPoints,
            "With speedGain = 0, audioLevel must NOT change the rendered path — that's the contract that keeps thinking + idle stable."
        )
    }

    /// Sanity ceiling for runaway audio gain: per Maxim's iteration, loud
    /// audio IS allowed to expand the BlobShape bounding box significantly
    /// (he tuned `deformationGain` up to peak ~17x). This test only catches
    /// catastrophic runaway (e.g. accidental multiplicative scaling that
    /// blows up to thousands × baseline).
    func testBlobShapeAudioBoundingBoxStaysWithinSanityCeiling() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        let quiet = BlobShape(
            phase: 1.0,
            seedOffset: 0.3,
            audioLevel: 0.0,
            harmonics: .primary,
            freedom: 0,
            speedGain: 2.5
        )
        let loud = BlobShape(
            phase: 1.0,
            seedOffset: 0.3,
            audioLevel: 1.0,
            harmonics: .primary,
            freedom: 0,
            speedGain: 2.5
        )

        let quietWidth = quiet.path(in: rect).boundingRect.width
        let loudWidth = loud.path(in: rect).boundingRect.width

        let relativeDelta = abs(loudWidth - quietWidth) / max(quietWidth, 0.001)
        XCTAssertLessThan(
            relativeDelta, 5.0,
            "Sanity ceiling — loud audio must not balloon the BlobShape's bounding box past 5x quiet baseline (catches runaway multiplicative scaling). q=\(quietWidth) l=\(loudWidth)"
        )
    }

    // MARK: - Adaptive core color (white-core in adaptiveBlack flavour)

    /// Maxim asked for the core of the orb to **invert** with the
    /// palette: white rings + black core over a dark wallpaper (as
    /// before), black rings + WHITE core over a light wallpaper. This
    /// gives the inner volume on a light background instead of a flat
    /// black blob.
    ///
    /// Pinned via a public selector `VoiceOrbView.coreColor(for:)` so
    /// the value is testable in isolation without rendering.
    func testCoreColorIsBlackOnAdaptiveWhitePalette() {
        XCTAssertEqual(
            VoiceOrbView.coreColor(for: .adaptiveWhite),
            .black,
            "White-on-dark orb keeps its black core — the centre stays dark so the silhouette reads."
        )
    }

    func testCoreColorIsWhiteOnAdaptiveBlackPalette() {
        XCTAssertEqual(
            VoiceOrbView.coreColor(for: .adaptiveBlack),
            .white,
            "Black-on-light orb gets a WHITE core so the orb has volume rather than reading as a flat black blob."
        )
    }

    func testCoreColorIsBlackOnAgentPinkVioletPalette() {
        XCTAssertEqual(
            VoiceOrbView.coreColor(for: .pinkViolet),
            .black,
            "Agent pink-violet orb keeps the black core — that's the Apple-Intelligence reference look."
        )
    }

    // MARK: - Round 4 Fix C: shimmering pink-violet gradient

    /// Maxim's round-4 ask: the agent text-input mode's gradient ring
    /// must read as "shimmering pink-violet" — a visible alternation
    /// between pink and violet, not "mostly violet with a hint of
    /// pink". Counted via a pink-stop check: a stop is "pink" when its
    /// red component clearly dominates its blue component (the pink
    /// stop we ship has roughly red 0.97 > blue 0.85, while the
    /// violets all have blue > red). Two pink stops in the cycle =
    /// alternating shimmer; one or zero = the regression Maxim
    /// flagged.
    func testPinkVioletGradientHasAtLeastTwoPinkStops() {
        let stops = VoiceOrbView.PaletteFlavor.pinkViolet.gradientRingStops

        let pinkStops = stops.filter { rgbComponents(of: $0).red > rgbComponents(of: $0).blue }
        XCTAssertGreaterThanOrEqual(
            pinkStops.count, 2,
            "Pink-violet gradient must have at least 2 pink stops (red > blue) so the rotating ring reads as alternating pink+violet, not 'mostly violet'. Got \(pinkStops.count). Full stops: \(stops.map { rgbComponents(of: $0) })"
        )
    }

    /// Pin a floor on the rotation rate so the ring reads as shimmering
    /// rather than slow drifting. Round-3 used `time * 1.0` (~6.3s per
    /// rotation) which Maxim read as static violet. Round-4 raises
    /// that multiplier — anything ≥ 2.0 rad/sec produces one rotation
    /// in under ~3.2s, which reads as live motion.
    func testGradientRingRotationRateIsShimmeringFast() throws {
        let source = try loadVoiceOrbSource()
        let body = try extractFunctionBody(
            source: source,
            header: "private func gradientRing(time: Double) -> some View"
        )

        // Find the `Angle.radians(time * N)` literal and assert N ≥ 2.0.
        // The expression sits on one line in the current implementation.
        guard let range = body.range(of: "Angle.radians(time *") else {
            return XCTFail("Could not find rotation rate in gradientRing body — has the angle expression been refactored? Body:\n\(body)")
        }
        let tail = body[range.upperBound...]
        let multiplierString = tail
            .prefix(while: { $0 != ")" })
            .trimmingCharacters(in: .whitespaces)
        guard let multiplier = Double(multiplierString) else {
            return XCTFail("Could not parse rotation multiplier `\(multiplierString)` as Double — expression refactored?")
        }
        XCTAssertGreaterThanOrEqual(
            multiplier, 2.0,
            "Gradient ring rotation multiplier must be ≥ 2.0 rad/sec so the ring reads as shimmering. Round-3's 1.0 was too slow ( Maxim: \"просто фиолетовое\")."
        )
    }

    // RGB helper — extracts the three colour components from a SwiftUI
    // `Color` via the AppKit bridge. Tests run on macOS so the bridge
    // is always available.
    private func rgbComponents(of color: Color) -> (red: Double, green: Double, blue: Double) {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return (
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent)
        )
    }

    // MARK: - Wake-from-sleep hang anti-regression
    //
    // After sleep, `Date()` jumps forward by hours. The previous
    // implementation fed `context.date.timeIntervalSinceReferenceDate`
    // (an absolute wall-clock value of order 8 × 10^8 seconds) directly
    // into BlobShape's animatable `phase` / swirl / spinAngle. The
    // parent `.animation(_:value:)` modifiers on `mode` / `palette` /
    // `isDarkBackground` / `state.phase` / `state.agentPhase` propagate
    // implicit animations down to BlobShape's `animatableData`. On wake,
    // the cross-sleep `time` discontinuity (millions of phase units of
    // jump) collides with that implicit animation: SwiftUI's
    // `DefaultCombiningAnimation` tries to interpolate the giant delta
    // and never converges — the main thread spends 100% of its time in
    // `Array._makeMutableAndUnique` copying DisplayList properties.
    //
    // The fix has two complementary parts that this test block guards:
    //
    // 1. **Session-relative `time`**: anchor TimelineView's `time` to a
    //    per-view `@State` epoch instead of the absolute reference
    //    interval. After a sleep the post-wake `time` jumps by the sleep
    //    duration (seconds), not by the elapsed wall-clock since 2001.
    //
    // 2. **`.transaction { animation = nil }` wrap**: isolate the
    //    BlobShape stack and gradient ring from parent
    //    `.animation(_:value:)` modifiers so SwiftUI does NOT implicitly
    //    interpolate BlobShape's animatableData on top of
    //    TimelineView's per-frame updates. Continuous motion already
    //    comes from TimelineView ticks; the implicit animations only
    //    add jank and (catastrophically, after a sleep jump) hang the
    //    main thread.

    /// Pin the `@State` epoch declaration so the time anchoring above
    /// can't silently drift back to absolute wall-clock.
    func testVoiceOrbViewDeclaresTimeReferenceState() throws {
        let source = try loadVoiceOrbSource()
        XCTAssertTrue(
            source.contains("@State private var timeReference"),
            "VoiceOrbView must declare a per-view `@State private var timeReference` so TimelineView's `time` is anchored to a session-relative epoch, not absolute wall-clock. Absolute wall-clock as a BlobShape phase input causes the post-wake hang."
        )
    }

    /// `time` inside the TimelineView body must subtract `timeReference`
    /// from `context.date.timeIntervalSinceReferenceDate`. The body must
    /// not feed the absolute reference interval directly into BlobShape.
    func testTimelineViewBodyAnchorsTimeToReference() throws {
        let source = try loadVoiceOrbSource()
        let bodyBody = try extractFunctionBody(source: source, header: "var body: some View")

        XCTAssertTrue(
            bodyBody.contains("timeReference"),
            "TimelineView body must consume `timeReference` so `time` is session-relative, not absolute wall-clock. Body:\n\(bodyBody)"
        )
        // The unanchored absolute form (without subtraction) was the
        // exact trigger — flag any straight assignment of the absolute
        // interval to a local named `time` that isn't followed by a
        // subtraction of the reference.
        XCTAssertFalse(
            bodyBody.contains("let time = context.date.timeIntervalSinceReferenceDate\n"),
            "TimelineView body must NOT assign the absolute wall-clock interval directly to `time` — feeding it into BlobShape's phase causes the post-wake hang. Subtract `timeReference` first. Body:\n\(bodyBody)"
        )
    }

    /// The active orb composition (BlobShape stack) must be wrapped in a
    /// `.transaction { ... animation = nil ... }` so implicit animations
    /// from parent `.animation(_:value:)` modifiers on `mode` / `palette`
    /// / `isDarkBackground` / phase don't propagate into BlobShape's
    /// `animatableData`. Without this isolation, the post-wake `time`
    /// jump becomes a giant animated interpolation that hangs the main
    /// thread.
    func testActiveOrbWrapsBlobShapeInTransactionDisablingAnimation() throws {
        let source = try loadVoiceOrbSource()
        let activeOrbBody = try extractFunctionBody(source: source, header: "private func activeOrb(")

        XCTAssertTrue(
            activeOrbBody.contains(".transaction"),
            "activeOrb must wrap its BlobShape stack in `.transaction { ... }` to disable inherited implicit animations. Without it, parent `.animation(_:value:)` on mode/palette/isDarkBackground propagates into BlobShape.animatableData and a post-sleep `time` jump hangs the main thread. Body:\n\(activeOrbBody)"
        )
        // Pin that the transaction kills `animation` (the property
        // SwiftUI reads to decide whether to interpolate).
        XCTAssertTrue(
            activeOrbBody.contains("animation = nil") || activeOrbBody.contains("animation=nil"),
            "activeOrb's `.transaction` block must explicitly set `transaction.animation = nil` so SwiftUI does not implicitly interpolate BlobShape's animatableData. Body:\n\(activeOrbBody)"
        )
    }

    /// Same isolation for the gradient ring (text-input mode). It also
    /// derives its rotation angle from `time` and is rendered when
    /// `agentPhase == .textInputActive` is flipping in/out under
    /// parent `.animation(_:value:)` modifiers.
    func testGradientRingWrapsInTransactionDisablingAnimation() throws {
        let source = try loadVoiceOrbSource()
        let gradientRingBody = try extractFunctionBody(
            source: source,
            header: "private func gradientRing(time: Double) -> some View"
        )

        XCTAssertTrue(
            gradientRingBody.contains(".transaction"),
            "gradientRing must wrap its Circle.stroke + AngularGradient in `.transaction { ... }` to disable inherited implicit animations. Body:\n\(gradientRingBody)"
        )
        XCTAssertTrue(
            gradientRingBody.contains("animation = nil") || gradientRingBody.contains("animation=nil"),
            "gradientRing's `.transaction` block must explicitly set `transaction.animation = nil`. Body:\n\(gradientRingBody)"
        )
    }
}

// MARK: - Path sampling helper (Tests)

private extension Path {
    /// Samples `steps` evenly-spaced points along the path's bbox
    /// border-by-border so we can compare two paths element-wise in
    /// tests. We don't need perfect tessellation — just enough to
    /// detect "did anything change" between two `path(in:)` calls.
    func samplePoints(steps: Int) -> [CGPoint] {
        var points: [CGPoint] = []
        forEach { element in
            switch element {
            case .move(let p), .line(let p):
                points.append(p)
            case .quadCurve(let p, _), .curve(let p, _, _):
                points.append(p)
            case .closeSubpath:
                break
            }
        }
        // Down-sample if too many points to keep equality fast.
        if points.count > steps && steps > 0 {
            let stride = max(1, points.count / steps)
            return Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
        }
        return points
    }
}
