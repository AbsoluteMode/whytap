import SwiftUI
#if DEBUG
import os.log
#endif

#if DEBUG
/// DEBUG-only logger for diagnosing suspected orb animation freeze.
/// The probe logs `time`, audio `energy`, and the orb's smoothed audio
/// level so a freeze is obvious from the log:
///
///     log show --predicate 'subsystem == "com.rootwise.sidekey" \
///         && category == "orb"' --last 30s --info --debug
///
/// If `time` advances and `smoothed` drifts between log entries, the
/// orb is animating live.
///
/// Throttled to one entry per ~0.5s to avoid log spam. Only emits in
/// active modes (idle / text-input have their own animation models).
private let orbLog = OSLog(subsystem: "com.rootwise.sidekey", category: "orb")
#endif

enum VoiceOrbMode: Equatable {
    case idle
    case dropVoice
    case dropProcessing
    case agentVoice
    case agentProcessing
    /// Agent text-input panel is on screen: render a gradient ring (not a
    /// filled orb) so the user has a clear "I am here, I am listening for
    /// text, no request in flight yet" affordance.
    case agentTextInputActive
    case googleVoice
    case googleTextInputActive

    var isActive: Bool {
        self != .idle
    }

    var isVoiceDriven: Bool {
        self == .dropVoice || self == .agentVoice || self == .googleVoice
    }

    var isAgent: Bool {
        self == .agentVoice
            || self == .agentProcessing
            || self == .agentTextInputActive
    }

    var isGoogle: Bool {
        switch self {
        case .googleVoice, .googleTextInputActive: return true
        default: return false
        }
    }
}

/// Voice/agent orb. `orbSize` orb on a `canvasSize` canvas
/// (`glowMargin` per side). Post-shrink + glow-padding: 25pt orb on a
/// 57pt canvas (16pt glow margin) — see `orbSize` / `glowMargin` /
/// `canvasSize` below for the live numeric floors.
///
/// **Why the canvas is much larger than the visible orb.** The active
/// orb composites a wide bloom (`endRadius ≈ orbSize` from the orb
/// centre) plus an 18pt+ blur on top. With a tight canvas (orbSize +
/// 2*8pt) the radial-fade halo mask had to reach alpha 0 right at the
/// canvas edge midpoint, while the canvas corners sat ~1.41× past that
/// — under the right glow gradient the residual bloom alpha at the
/// corners produced a visible "square frame around the round orb"
/// regression. Widening the canvas (16pt glow margin) gives the mask
/// enough room to fade the bloom well before the corners, so the
/// transparent NSPanel edges read as round even under bright glow.
///
/// Composition per mode:
///
/// - `idle` → not really rendered (DotView shows the static circle); the
///   composition selector still maps to `.ring` for backward compatibility.
/// - `dropVoice`, `dropProcessing`, `agentVoice`, `agentProcessing` → the
///   active Siri-style orb (`activeOrb`).
/// - `agentTextInputActive` → static gradient ring (`gradientRing`),
///   same footprint as the idle ring so the orb does not jump position.
///
/// Palette selection:
///
/// - Drop (`dropVoice`, `dropProcessing`) is adaptive: white-on-dark or
///   black-on-light, depending on the `isDarkBackground` argument supplied
///   by `BackgroundLuminanceObserver`.
/// - Agent (`agentVoice`, `agentProcessing`, `agentTextInputActive`) is
///   the fixed pink-violet gradient — the "AI agent flavour" reads the
///   same regardless of the wallpaper underneath.
///
/// The active orb itself is a stack of `BlobShape` strokes (the harmonic
/// sum-of-sines wobble shape, adapted from the Siri-orb reference). 1
/// outer bloom + 1 halo + 7 strokes + an inner reflection + a black core
/// = the same volumetric read as Maxim's reference image.
///
/// `TimelineView(.animation)` drives all motion — no Timer, no `@State`
/// spam per frame.
struct VoiceOrbView: View {
    /// Orb diameter in points. Maxim's 30% vertical-shrink directive
    /// («всю рамку правую + карточки уменьшить по вертикали») applied
    /// to the original 36pt orb, rounded to nearest 1pt → 25pt. The orb
    /// is a `Circle`, so this also reduces the horizontal footprint —
    /// accepted side-effect for a round shape since a single-axis
    /// shrink of a circle is geometrically meaningless.
    static let orbSize: CGFloat = 25
    /// Halo bleed around the orb. Was 8pt (PR #123 shrink) until the
    /// «квадрат вокруг round orb» regression on build 1107: with only
    /// 8pt of margin the radial-fade halo mask reached alpha 0 right at
    /// the canvas edge midpoint, so corner pixels (~1.41× past
    /// `canvasSize/2`) sat past the gradient and the residual bloom
    /// alpha bled into them — visible square frame under the orb.
    /// Bumped to 16pt so the mask's endRadius (= canvasSize/2 = 28.5pt)
    /// sits comfortably past the bloom's natural extent (≈ orbSize =
    /// 25pt) and the corners fall well past the fade-to-zero ring. The
    /// orb's visible size (`orbSize = 25pt`) is unchanged — the extra
    /// margin is transparent buffer, not larger orb.
    static let glowMargin: CGFloat = 16
    /// Total panel canvas (orb + halo bleed per side). Derives to 57pt
    /// after the glow-padding bump (25 + 16*2). The previous value was
    /// 41pt (8pt glow margin); the pre-shrink value before PR #123 was
    /// 60pt (12pt glow margin) — the new 57pt is close to the
    /// pre-shrink size by coincidence, since we essentially restored
    /// the pre-shrink glow buffer to fix the square-frame regression
    /// while keeping the visible orb at its post-shrink 25pt diameter.
    static let canvasSize: CGFloat = orbSize + glowMargin * 2
    static let silenceEnergyThreshold: CGFloat = 0.0001
    static let voiceNoiseGate: CGFloat = 0.04

    /// Which top-level element the view renders for a given mode.
    enum Composition: Equatable {
        case ring
        case gradientRing
        case activeOrb
    }

    /// Which colour palette to apply. Independent from `Composition` so
    /// drop modes can adapt while agent modes stay fixed.
    enum PaletteFlavor: Equatable {
        /// White rings + soft white halo. Used when the orb sits over
        /// a dark background (drop flow).
        case adaptiveWhite
        /// Black rings + soft dark halo. Used when the orb sits over a
        /// light background (drop flow).
        case adaptiveBlack
        /// Fixed pink-violet gradient. Used for the agent flow (Cmd-tap)
        /// regardless of background — the "AI agent" identity.
        case pinkViolet
        /// Fixed Google brand colors. Used for the Google-search flow (R-Option)
        /// regardless of background - the "Google" identity.
        case google
    }

    static func composition(for mode: VoiceOrbMode) -> Composition {
        switch mode {
        case .idle:
            return .ring
        case .agentTextInputActive, .googleTextInputActive:
            return .gradientRing
        case .dropVoice, .dropProcessing, .agentVoice, .agentProcessing, .googleVoice:
            return .activeOrb
        }
    }

    /// Resolves the palette flavour for a given mode + background. The
    /// drop flow adapts to the background; the agent flow is fixed.
    /// Idle is treated as "drop" since the static circle should pick
    /// the contrasting colour too.
    static func paletteFlavor(
        for mode: VoiceOrbMode,
        isDarkBackground: Bool
    ) -> PaletteFlavor {
        if mode.isGoogle {
            return .google
        }
        if mode.isAgent {
            return .pinkViolet
        }
        return isDarkBackground ? .adaptiveWhite : .adaptiveBlack
    }

    /// The colour the inner core of the orb fills with. White-on-dark
    /// orbs (adaptive white) keep a BLACK core — the silhouette reads
    /// because the centre is dark while the rings glow white. Black-on
    /// -light orbs (adaptive black) invert: the rings are black and the
    /// CORE is white, so the orb has visible inner volume over a bright
    /// wallpaper instead of reading as a flat black blob. Agent
    /// pink-violet keeps the black core (Apple-Intelligence reference).
    ///
    /// Exposed as a static selector so tests can pin the mapping
    /// without rendering.
    static func coreColor(for palette: PaletteFlavor) -> Color {
        switch palette {
        case .adaptiveWhite:
            return .black
        case .adaptiveBlack:
            return .white
        case .pinkViolet:
            return .black
        case .google:
            return .black
        }
    }

    let mode: VoiceOrbMode
    let levels: [Float]
    let isDarkBackground: Bool

    /// Existing call sites pass only `mode:` and `levels:` — keep the
    /// older two-argument init working so DotView / tests don't break
    /// during the rollout. The default `isDarkBackground = false` reads
    /// as "light background" → black orb, which is the safer first paint
    /// before the observer has reported.
    init(
        mode: VoiceOrbMode,
        levels: [Float],
        isDarkBackground: Bool = false
    ) {
        self.mode = mode
        self.levels = levels
        self.isDarkBackground = isDarkBackground
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-session epoch used to anchor TimelineView's `time` to a
    /// session-relative value instead of `Date()` wall-clock.
    ///
    /// **Why this exists.** Before this state, the body fed
    /// `context.date.timeIntervalSinceReferenceDate` (an absolute
    /// wall-clock value of order 8 × 10^8 seconds) directly into
    /// `BlobShape.phase` / `swirl` / `spinAngle` / `gradientRing.angle`.
    /// After a system sleep, `Date()` jumps forward by hours; the
    /// derived `time` (and everything multiplied off it) jumps by
    /// millions of phase units. Parent `.animation(_:value:)` modifiers
    /// on `mode`, `palette`, `isDarkBackground`, and the surrounding
    /// `state.phase` / `state.agentPhase` propagate implicit animations
    /// into BlobShape's `animatableData`. SwiftUI's
    /// `DefaultCombiningAnimation` cannot converge an interpolation of
    /// that magnitude — the main thread spins at 100% in
    /// `Array._makeMutableAndUnique` copying DisplayList properties and
    /// the orb hangs for tens of seconds (often longer than the user's
    /// patience).
    ///
    /// Anchoring `time` to a per-view `@State` epoch makes the post-wake
    /// jump bounded by the sleep duration in seconds (not absolute
    /// wall-clock since 2001). Combined with the `.transaction { ...
    /// animation = nil ... }` isolation around `activeOrb` /
    /// `gradientRing`, BlobShape's animatableData receives only
    /// TimelineView's per-frame ticks — never an implicit interpolation
    /// across a discontinuity.
    @State private var timeReference: TimeInterval? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 20.0 : 1.0 / 60.0, paused: mode == .idle)) { context in
            // Reduced Motion: pin the timeline so the orb stops breathing
            // and rotating. The orb still appears, it just stops animating.
            //
            // Live path: subtract `timeReference` so `time` is
            // session-relative. On the first frame `timeReference` is
            // still nil — fall back to the current absolute interval so
            // delta is zero, then the `.onAppear` below seeds the
            // reference for subsequent frames. Either way the value fed
            // into BlobShape phase / gradient angle stays bounded.
            let absoluteTime = context.date.timeIntervalSinceReferenceDate
            let referenceTime = timeReference ?? absoluteTime
            let time = reduceMotion ? 0 : (absoluteTime - referenceTime)
            let energy = Self.displayEnergy(levels: levels, time: time, mode: mode)
            let palette = Self.paletteFlavor(for: mode, isDarkBackground: isDarkBackground)

            // Throttled animation probe (DEBUG only).
            let _ = debugProbe(time: time, energy: energy)

            ZStack {
                switch Self.composition(for: mode) {
                case .ring:
                    idleRing(palette: palette)
                        .transition(.opacity)
                case .gradientRing:
                    gradientRing(time: time, palette: palette)
                        .transition(.opacity)
                case .activeOrb:
                    activeOrb(time: time, energy: energy, palette: palette)
                        .transition(.scale(scale: 0.25).combined(with: .opacity))
                }
            }
            .frame(width: Self.canvasSize, height: Self.canvasSize)
            // Soft radial-fade mask. The previous `mask(Circle())` left
            // a visible sharp edge around the bloom on visual review
            // (Maxim flagged a "rough circle outline" around the active
            // orb). A radial gradient mask keeps the centre fully opaque,
            // tapers off through the glow margin, and reaches alpha 0
            // right at the canvas edge — bloom dissolves smoothly into
            // the panel instead of getting chopped off.
            //
            // Going hard 0-alpha at the edge instead of just dropping the
            // mask preserves the bloom-doesn't-leak invariant from
            // commit 072b66e (alpha leak in the canvas corners caused
            // the original "square halo" regression).
            .mask(softHaloMask)
            .animation(.easeInOut(duration: 0.22), value: mode)
            .animation(.easeInOut(duration: 0.30), value: palette)
            .allowsHitTesting(false)
        }
        .onAppear {
            if timeReference == nil {
                timeReference = Date().timeIntervalSinceReferenceDate
            }
        }
    }

    /// Radial-gradient mask covering the `canvasSize` square. Opaque
    /// from centre out to ~55% radius (well past the outermost orb
    /// ring), then fades to alpha 0 at the canvas edge. The bloom's
    /// blurred halo lives in the `glowMargin` margin between the orb
    /// edge and the canvas edge — the gradient dissolves it smoothly
    /// instead of chopping it with a hard circle mask. The fractions
    /// below are scale-invariant; the absolute pt sizes shifted with
    /// Maxim's PR #123 shrink (canvasSize 60 → 41, glowMargin 12 → 8)
    /// and again with the glow-padding bump (canvasSize 41 → 57,
    /// glowMargin 8 → 16) — but the gradient relationships still hold.
    /// `endRadius: canvasSize/2 = 28.5pt` now sits comfortably past the
    /// bloom's natural extent (≈ orbSize = 25pt) so the corner pixels
    /// (~40pt from centre, well past endRadius) reliably reach alpha 0.
    ///
    /// Stops correspond to canvas-radius fractions:
    /// - 0.00 ... 0.55  fully opaque (orb body, all rings)
    /// - 0.84            ~55% opaque (visible halo, still strong)
    /// - 1.00            alpha 0 (canvas edge — no hard outline)
    private var softHaloMask: some View {
        Rectangle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white, location: 0.55),
                        .init(color: Color.white.opacity(0.55), location: 0.84),
                        .init(color: Color.white.opacity(0.0), location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: Self.canvasSize / 2
                )
            )
            .frame(width: Self.canvasSize, height: Self.canvasSize)
    }

    /// DEBUG-only animation probe (Bug 2 diagnostic). No-op in release.
    private func debugProbe(time: Double, energy: CGFloat) {
        #if DEBUG
        guard mode.isActive else { return }
        let bucket = Int(time * 2)
        guard bucket % 4 == 0 else { return }
        os_log(
            "orb tick mode=%{public}@ time=%.3f energy=%.3f",
            log: orbLog,
            type: .info,
            String(describing: mode),
            time,
            Double(energy)
        )
        #endif
    }

    static func audioEnergy(levels: [Float]) -> CGFloat {
        // Use the most recent raw sample, not a 10-sample average.
        // Symmetric averaging makes pauses take ~10 frames to register,
        // which Maxim explicitly rejected: «реакция на паузу должна
        // быть быстрой». Smoothing is now done downstream by
        // `AudioEnergyFollower` with asymmetric attack/decay.
        guard let last = levels.last else { return 0 }
        return CGFloat(max(0, min(1, last)))
    }

    static func displayEnergy(levels: [Float], time: Double, mode: VoiceOrbMode) -> CGFloat {
        switch mode {
        case .idle, .agentTextInputActive, .googleTextInputActive:
            return 0
        case .dropVoice, .agentVoice, .googleVoice:
            // Three stages:
            //   1. Adaptive gate keyed on the user's learned noise
            //      floor (clamped [0.02, 0.1]) — anything below is
            //      room tone, follower is actively driven to 0 so the
            //      orb collapses fast on a pause.
            //   2. Above the gate, normalize raw audio into the user's
            //      learned [floor, peak] range — the orb expands
            //      fully at the user's typical loud speech regardless
            //      of microphone sensitivity.
            //   3. Asymmetric follower smooths normalized energy
            //      (moderate attack, fast decay so pauses register
            //      instantly).
            let rawAudio = audioEnergy(levels: levels)
            let rawGate = CGFloat(NoiseFloorEstimator.shared.floor) + 0.01
            let dynamicGate = max(0.02, min(0.1, rawGate))
            if rawAudio <= dynamicGate {
                let decayed = AudioEnergyFollower.shared.observe(0)
                return CGFloat(decayed)
            }
            let normalized = NoiseFloorEstimator.shared.normalize(Float(rawAudio))
            let smoothed = AudioEnergyFollower.shared.observe(normalized)
            return min(1.0, CGFloat(smoothed))
        case .dropProcessing, .agentProcessing:
            return 0.22 + CGFloat((sin(time * 2.6) + 1) * 0.10)
        }
    }

    // MARK: - Idle (rendered for `.idle` mode — TimelineView paused, no per-frame work)

    // Halo behind the main ring (ZStack stacks back-to-front) so the soft
    // halo lifts the stroked silhouette off the wallpaper without washing
    // it out. Numerics match the previous DotView.idleRing production look.
    private func idleRing(palette: PaletteFlavor) -> some View {
        let baseColor = palette.foreground
        return ZStack {
            Circle()
                .stroke(baseColor.opacity(0.22), lineWidth: 6)
                .frame(width: Self.orbSize + 4, height: Self.orbSize + 4)
                .blur(radius: 4)

            Circle()
                .stroke(baseColor.opacity(0.92), lineWidth: 2.2)
                .frame(width: Self.orbSize, height: Self.orbSize)
        }
    }

    // MARK: - Active orb (Siri-style BlobShape multi-ring stack)

    /// The Siri-style orb. Composition (back to front):
    ///   1. Outer bloom (filled BlobShape, radial gradient, heavy blur)
    ///   2. Outer halo (filled BlobShape, radial gradient, mid blur)
    ///   3. Ring 1: fat soft outer (primary harmonics)
    ///   4. Ring 2: lavender / accent mid (secondary harmonics)
    ///   5. Ring 3: counter-rotating (quaternary harmonics)
    ///   6. Ring 4: crisp highlight (tertiary harmonics)
    ///   7. Ring 5: crisp wisp (secondary harmonics)
    ///   8. Ring 6: thin filament (quaternary harmonics)
    ///   9. Ring 7: inner reflection (tertiary harmonics)
    ///  10. Black core (filled BlobShape, radial gradient — keeps the
    ///      centre dark when palette is white-on-dark; gently inverted
    ///      via the palette helpers for the black-on-light flow)
    ///
    /// `thinking` flow (processing modes) routes through `.rotationEffect`
    /// on the whole stack so the orb spins as a rigid body. `listening`
    /// flow (voice modes) leaves the rotation pinned and lets the
    /// BlobShapes wobble in place.
    ///
    /// **Audio reactivity**: `energy` is baked into every BlobShape's
    /// `audioLevel`, into stroke widths, blur radii, and opacities. The
    /// orb itself NEVER scales — scale-effect on a hollow ring reads as
    /// zoom, which fights the breathing feel.
    private func activeOrb(
        time: Double,
        energy: CGFloat,
        palette: PaletteFlavor
    ) -> some View {
        let profile = stateProfile
        // `lvl` is the working audio level inside the orb (smoothed
        // 0..1). Clamped at 1.0 defensively. Note: `lvl` is NO LONGER
        // multiplied into BlobShape audioLevel for amplitude — the
        // BlobShape uses it only for phase acceleration via
        // `speedGain`. Layer-level stroke widths / blur radii still
        // grow slightly with `lvl` because that's how the GLOW reads
        // brighter on loud speech (intensity, not size).
        let lvl = min(1.0, Double(energy) * profile.audioGain)
        // `t` is the master phase: scales `time` by profile tempo so
        // listening flows feel responsive and processing flows feel slow.
        //
        // `time` is ALWAYS continuous — no teleport-to-zero when audio
        // dips below a threshold. The previous round (`Codex`) gated the
        // entire motion clock on `mode.isVoiceDriven && lvl <= silenceEnergyThreshold`,
        // which made room tone produce visible jitter at the threshold
        // boundary. Continuity here is non-negotiable; the noise gate
        // in `displayEnergy` already handles "don't react to mic hiss"
        // as a smooth amplitude curve, not a phase teleport.
        // NOTE: do NOT multiply `time` by an audio-dependent factor.
        // `time` is wall-clock (~8e8 seconds since 2001), so any
        // `multiplier * time` where multiplier changes between frames
        // produces phase jumps of order `time * delta(multiplier)`,
        // i.e. hundreds of thousands of phase units — sin() argument
        // becomes effectively random and the orb "explodes" into
        // chaotic motion. The right channel for audio→motion lives in
        // BlobShape's additive `speedGain` offset (continuous in audio,
        // bounded magnitude).
        let t = time * 0.85 * profile.tempo
        // `swirl` is a slow global rotation of the harmonic phases,
        // active in processing flows where each layer drifts in its own
        // orbit.
        let swirl = time * 0.25 * profile.swirl
        // `breath` modulates the canvas radius — slow rise/fall ONLY,
        // no audio kick (would re-inflate the orb with audio).
        let breath = 1.0 + sin(time * 0.7 * profile.breath) * 0.04
        // Rigid-body spin angle for processing flows.
        let spinAngle = time * profile.spin
        // Shared freedom + speedGain piped into every BlobShape so the
        // sway and phase-acceleration are consistent across layers.
        let freedom = profile.freedom
        let speedGain = profile.speedGain

        // Working radius. The reference targets `size * 0.22` of a
        // fullscreen canvas; ours is `canvasSize` with `orbSize` body so
        // the working radius hovers near `orbSize/2` (post 30% shrink:
        // ~12.5pt, was ~18pt).
        let baseR = (Self.orbSize / 2) * CGFloat(breath)

        return ZStack {
            // 1. OUTER BLOOM
            BlobShape(
                phase: t * 0.45 + swirl,
                seedOffset: 0.2,
                audioLevel: lvl * 0.5,
                harmonics: .primary,
                // Bloom takes half the freedom — sway is fine on the
                // edges, but a too-wobbly bloom muddles the silhouette.
                freedom: freedom * 0.5,
                speedGain: speedGain
            )
            .fill(palette.outerBloomGradient(baseR: baseR))
            .frame(width: baseR * 2 * 1.55, height: baseR * 2 * 1.55)
            .blur(radius: 18 + CGFloat(lvl) * 6)

            // 2. OUTER HALO
            BlobShape(
                phase: t * 0.6 + swirl * 0.7,
                seedOffset: 0.5,
                audioLevel: lvl * 0.6,
                harmonics: .primary,
                freedom: freedom * 0.7,
                speedGain: speedGain
            )
            .fill(palette.outerHaloGradient(baseR: baseR))
            .frame(width: baseR * 2 * 1.30, height: baseR * 2 * 1.30)
            .blur(radius: 9 + CGFloat(lvl) * 4)

            // 3. RING 1 — fat soft outer (full freedom; the biggest
            //    ring carries the most visible sway).
            BlobShape(
                phase: t + swirl,
                seedOffset: 0.3,
                audioLevel: lvl * profile.wobbleGain,
                harmonics: .primary,
                freedom: freedom,
                speedGain: speedGain
            )
            .stroke(
                palette.color1.opacity(0.95),
                style: StrokeStyle(
                    lineWidth: 6.5 + CGFloat(lvl) * 4,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: baseR * 2, height: baseR * 2)
            .blur(radius: 3.5 + CGFloat(lvl) * 2)

            // 4. RING 2 — lavender / accent mid (full freedom).
            BlobShape(
                phase: t * 1.1 + 0.6 + swirl,
                seedOffset: 1.7,
                audioLevel: lvl * profile.wobbleGain,
                harmonics: .secondary,
                freedom: freedom,
                speedGain: speedGain
            )
            .stroke(
                palette.color2.opacity(0.95),
                style: StrokeStyle(
                    lineWidth: 4.0 + CGFloat(lvl) * 2.6,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: baseR * 2 * 1.005, height: baseR * 2 * 1.005)
            .blur(radius: 2.0 + CGFloat(lvl) * 1.5)

            // 5. RING 3 — counter-rotating (full freedom).
            BlobShape(
                phase: -t * 0.85 + 2.1 - swirl,
                seedOffset: 3.4,
                audioLevel: lvl * profile.wobbleGain,
                harmonics: .quaternary,
                freedom: freedom,
                speedGain: speedGain
            )
            .stroke(
                palette.color3.opacity(0.85),
                style: StrokeStyle(
                    lineWidth: 2.4 + CGFloat(lvl) * 1.6,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: baseR * 2 * 1.012, height: baseR * 2 * 1.012)
            .blur(radius: 1.4 + CGFloat(lvl) * 1)

            // 6. RING 4 — crisp highlight (full freedom — the
            //    high-frequency jitter sits on top of the same sway,
            //    keeps the highlight from looking pasted-on).
            BlobShape(
                phase: t * 0.9 - 0.4 + swirl * 0.5,
                seedOffset: 2.9,
                audioLevel: lvl * profile.wobbleGain,
                harmonics: .tertiary,
                freedom: freedom,
                speedGain: speedGain
            )
            .stroke(
                palette.color4,
                style: StrokeStyle(
                    lineWidth: 1.0 + CGFloat(lvl) * 1.0,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: baseR * 2 * 0.995, height: baseR * 2 * 0.995)
            .blur(radius: 0.5 + CGFloat(lvl) * 0.4)

            // 7. RING 5 — crisp wisp
            BlobShape(
                phase: t * 1.25 + 1.6 + swirl * 0.4,
                seedOffset: 4.4,
                audioLevel: lvl * 0.7 * profile.wobbleGain,
                harmonics: .secondary,
                freedom: freedom * 0.8,
                speedGain: speedGain
            )
            .stroke(
                palette.color4.opacity(0.82),
                style: StrokeStyle(
                    lineWidth: 0.7 + CGFloat(lvl) * 0.6,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: baseR * 2 * 1.01, height: baseR * 2 * 1.01)
            .blur(radius: 0.3)

            // 8. RING 6 — thin filament
            BlobShape(
                phase: -t * 1.05 + 3.2 - swirl * 0.6,
                seedOffset: 5.8,
                audioLevel: lvl * 0.55 * profile.wobbleGain,
                harmonics: .quaternary,
                freedom: freedom * 0.8,
                speedGain: speedGain
            )
            .stroke(
                palette.color3.opacity(0.78),
                style: StrokeStyle(
                    lineWidth: 0.5 + CGFloat(lvl) * 0.4,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: baseR * 2 * 1.018, height: baseR * 2 * 1.018)
            .blur(radius: 0.3)

            // 9. RING 7 — inner reflection (reduced freedom — too much
            //    sway inside the core just visually muddies the centre).
            BlobShape(
                phase: t * 0.8 + 0.9 + swirl * 0.3,
                seedOffset: 6.1,
                audioLevel: lvl * 0.6,
                harmonics: .tertiary,
                freedom: freedom * 0.6,
                speedGain: speedGain
            )
            .stroke(
                palette.color2.opacity(0.6),
                style: StrokeStyle(
                    lineWidth: 0.8 + CGFloat(lvl) * 0.5,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: baseR * 2 * 0.91, height: baseR * 2 * 0.91)
            .blur(radius: 0.7 + CGFloat(lvl) * 0.4)

            // 10. INNER CORE — keep the centre well-shaped.
            BlobShape(
                phase: t * 0.75 + 0.3 + swirl,
                seedOffset: 1.1,
                audioLevel: lvl * 0.4,
                harmonics: .primary,
                freedom: freedom * 0.4,
                speedGain: speedGain
            )
            .fill(palette.coreGradient(baseR: baseR))
            .frame(width: baseR * 2 * 0.78, height: baseR * 2 * 0.78)
            .blur(radius: 1.6 + CGFloat(lvl) * 0.8)
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
        // Processing modes spin the whole stack as a rigid body.
        // `listening` modes (`profile.spin == 0`) leave this untouched.
        .rotationEffect(.radians(spinAngle))
        .compositingGroup()
        .animation(.easeOut(duration: 0.18), value: energy)
        // Isolate the BlobShape stack from inherited implicit animations.
        // Parent `.animation(_:value:)` modifiers on `mode`, `palette`,
        // `isDarkBackground`, `state.phase`, and `state.agentPhase` would
        // otherwise propagate down to `BlobShape.animatableData`. The
        // orb already draws smooth motion from TimelineView's per-frame
        // ticks — implicit interpolations on top are unnecessary and
        // become catastrophic after a sleep, when the `time` jump turns
        // into a `DefaultCombiningAnimation` interpolation the engine
        // cannot converge (main thread pinned at 100% in
        // DisplayList layout). This `.transaction` block null-routes
        // those inherited animations.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    // MARK: - State profiles

    /// Per-mode animation profile. Adapted from the reference implementation
    /// but stripped to the two modes we actually need (listening + thinking).
    /// Idle / text-input use the static rings, not the active stack.
    ///
    /// Fields:
    /// - `tempo`: master phase multiplier — fast for listening, slow for thinking.
    /// - `wobbleGain`: BlobShape harmonic amplitude. Stays at baseline
    ///   (~1.0) for listening because **audio drives speed, not size**.
    /// - `audioGain`: per-profile amplifier on the audio level fed into
    ///   the orb's working `lvl`. Stays near baseline for listening for
    ///   the same reason as `wobbleGain` — amplification of the
    ///   amplitude pipeline would inflate the rings, which is exactly
    ///   what we no longer want.
    /// - `speedGain`: how aggressively audio accelerates the BlobShape
    ///   harmonic phase. This is the audio → motion channel. Listening
    ///   is intentionally moderate; thinking is 0 (no audio input).
    /// - `swirl`: slow global phase drift across layers.
    /// - `breath`: canvas-radius modulation depth.
    /// - `spin`: rigid-body rotation speed (rad/sec). Listening = 0;
    ///   thinking spins so the user knows work is happening.
    /// - `freedom`: amplitude of the large-wavelength sway BlobShape
    ///   adds on top of the harmonics.
    struct StateProfile: Equatable {
        let tempo: Double
        let wobbleGain: Double
        let audioGain: Double
        let speedGain: Double
        let swirl: Double
        let breath: Double
        let spin: Double
        let freedom: Double
    }

    /// Static entry point exposed for unit tests (anti-regression on
    /// the numeric floors Maxim approved in visual review). The
    /// instance-level path goes through `stateProfile` (no argument) so
    /// the active orb composition reads the profile for `self.mode`.
    static func stateProfile(for mode: VoiceOrbMode) -> StateProfile {
        switch mode {
        case .dropVoice, .agentVoice, .googleVoice:
            // listening — **audio drives SPEED, not amplitude**, with
            // continuous (no teleport) phase. Codex's previous values
            // (tempo 0.70, speedGain 0.45, freedom 0.045) paired with
            // the now-removed conditional freeze read as static-then-jumpy;
            // those values are over-corrected now that the freeze is gone.
            //   * tempo 1.0  — visible motion at silence.
            //   * speedGain 1.5  — speech adds a clearly faster phase rate
            //     (1 + 1.0 * 1.5 = 2.5x at peaks).
            //   * freedom 0.2  — small but audible large-wavelength sway.
            //   * wobbleGain / audioGain at baseline so audio drives
            //     speed, not radius.
            return StateProfile(
                tempo: 1.0,
                wobbleGain: 1.0,
                audioGain: 1.0,
                speedGain: 8.0,
                swirl: 0.3,
                breath: 0.6,
                spin: 0,
                freedom: 0.2
            )
        case .dropProcessing, .agentProcessing:
            // thinking — no audio input, so speedGain = 0. Motion
            // comes from `spin` (rigid-body rotation) + `swirl` (phase
            // drift across layers).
            return StateProfile(
                tempo: 0.35,
                wobbleGain: 0.7,
                audioGain: 0,
                speedGain: 0,
                swirl: 1.0,
                breath: 1.4,
                spin: 2.5,
                freedom: 0.3
            )
        default:
            return StateProfile(
                tempo: 0,
                wobbleGain: 0,
                audioGain: 0,
                speedGain: 0,
                swirl: 0,
                breath: 0,
                spin: 0,
                freedom: 0
            )
        }
    }

    private var stateProfile: StateProfile {
        Self.stateProfile(for: mode)
    }

    // MARK: - Gradient ring (agent text-input panel open)

    private func gradientRing(time: Double, palette: PaletteFlavor = .pinkViolet) -> some View {
        // Palette is resolved by the caller from `paletteFlavor(for:isDarkBackground:)`,
        // so `.googleTextInputActive` gets `.google` colors and the agent flow keeps
        // `.pinkViolet`. Default preserved for any direct call sites.
        let stops = palette.gradientRingStops
        // Round 4: rotation speed bumped from 1.0 → 3.0 rad/sec
        // (~2.1s per full revolution). Round 3's 1.0 rad/sec rotation
        // (~6.3s per revolution) read as "просто фиолетовое" — the
        // pink slice barely moved. 3.0 rad/sec puts the alternating
        // pink+violet stops (`gradientRingStops` now carries two
        // pink occurrences) clearly into shimmer territory without
        // tipping into hectic / dizzying motion.
        let angle = Angle.radians(time * 3.0)

        return ZStack {
            Circle()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: stops),
                        center: .center,
                        angle: angle
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: Self.orbSize, height: Self.orbSize)
            Circle()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: stops.map { $0.opacity(0.55) }),
                        center: .center,
                        angle: angle
                    ),
                    lineWidth: 6
                )
                .frame(width: Self.orbSize, height: Self.orbSize)
                .blur(radius: 6)
        }
        // Same animation-isolation as `activeOrb`: the gradient angle is
        // derived from `time`, and `.agentTextInputActive` flips in/out
        // under parent `.animation(_:value:)` modifiers. Cutting inherited
        // animations off here prevents the rotating angle from being
        // interpolated across a sleep `time` discontinuity.
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - PaletteFlavor → colours

extension VoiceOrbView.PaletteFlavor {
    /// Foreground colour for the static idle ring (and any single-tone
    /// affordances). White on dark background, black on light background,
    /// indigo accent in the agent flavour.
    var foreground: Color {
        switch self {
        case .adaptiveWhite: return .white
        case .adaptiveBlack: return .black
        case .pinkViolet:    return Color(red: 0.59, green: 0.46, blue: 1.0)
        case .google:        return Color(red: 0.26, green: 0.52, blue: 0.96) // Google blue #4285F4
        }
    }

    /// Four working colours used across the 7-ring stack. The order is
    /// `color1` (fat outer) → `color2` (mid) → `color3` (counter-rotating
    /// wisps) → `color4` (crisp white highlight). Drop palettes drop the
    /// hue saturation to 0; agent palette is the violet / pink Apple-
    /// Intelligence read.
    var color1: Color {
        switch self {
        case .adaptiveWhite: return Color.white
        case .adaptiveBlack: return Color.black
        case .pinkViolet:    return Color(red: 0.55, green: 0.36, blue: 1.0) // indigo-violet
        case .google:        return Color(red: 0.26, green: 0.52, blue: 0.96) // #4285F4 blue
        }
    }

    var color2: Color {
        switch self {
        case .adaptiveWhite: return Color(white: 0.95)
        case .adaptiveBlack: return Color(white: 0.10)
        case .pinkViolet:    return Color(red: 0.79, green: 0.55, blue: 1.0) // light violet
        case .google:        return Color(red: 0.92, green: 0.26, blue: 0.21) // #EA4335 red
        }
    }

    var color3: Color {
        switch self {
        case .adaptiveWhite: return Color(white: 0.80)
        case .adaptiveBlack: return Color(white: 0.30)
        case .pinkViolet:    return Color(red: 0.97, green: 0.60, blue: 0.85) // pink accent
        case .google:        return Color(red: 0.98, green: 0.74, blue: 0.02) // #FBBC05 yellow
        }
    }

    var color4: Color {
        switch self {
        case .adaptiveWhite: return Color.white
        case .adaptiveBlack: return Color.black
        case .pinkViolet:    return Color(red: 0.99, green: 0.95, blue: 1.0) // crisp near-white
        case .google:        return Color(red: 0.20, green: 0.66, blue: 0.33) // #34A853 green
        }
    }

    /// Outer bloom — the widest, softest layer carrying most of the glow
    /// energy. Returns a `RadialGradient` so the bloom fades to fully
    /// transparent at the edge (no square bounding artefact even before
    /// the circle mask).
    func outerBloomGradient(baseR: CGFloat) -> RadialGradient {
        switch self {
        case .adaptiveWhite:
            return RadialGradient(
                colors: [
                    Color.white.opacity(0.55),
                    Color.white.opacity(0.20),
                    Color.white.opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.4,
                endRadius: baseR * 2.0
            )
        case .adaptiveBlack:
            return RadialGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.4,
                endRadius: baseR * 2.0
            )
        case .pinkViolet:
            return RadialGradient(
                colors: [
                    Color(red: 0.47, green: 0.37, blue: 1.0).opacity(0.65),
                    Color(red: 0.31, green: 0.39, blue: 0.94).opacity(0.32),
                    Color(red: 0.16, green: 0.24, blue: 0.71).opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.4,
                endRadius: baseR * 2.0
            )
        case .google:
            return RadialGradient(
                colors: [
                    color1.opacity(0.65),
                    color2.opacity(0.32),
                    color1.opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.4,
                endRadius: baseR * 2.0
            )
        }
    }

    /// Outer halo — tighter, brighter than the bloom; fills the volume
    /// between the bloom and the first ring.
    func outerHaloGradient(baseR: CGFloat) -> RadialGradient {
        switch self {
        case .adaptiveWhite:
            return RadialGradient(
                colors: [
                    Color.white.opacity(0.78),
                    Color.white.opacity(0.45),
                    Color.white.opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.6,
                endRadius: baseR * 1.5
            )
        case .adaptiveBlack:
            return RadialGradient(
                colors: [
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.40),
                    Color.black.opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.6,
                endRadius: baseR * 1.5
            )
        case .pinkViolet:
            return RadialGradient(
                colors: [
                    Color(red: 0.59, green: 0.46, blue: 1.0).opacity(0.78),
                    Color(red: 0.37, green: 0.41, blue: 0.90).opacity(0.45),
                    Color(red: 0.20, green: 0.25, blue: 0.69).opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.6,
                endRadius: baseR * 1.5
            )
        case .google:
            return RadialGradient(
                colors: [
                    foreground.opacity(0.78),
                    color1.opacity(0.45),
                    color1.opacity(0.0)
                ],
                center: .center,
                startRadius: baseR * 0.6,
                endRadius: baseR * 1.5
            )
        }
    }

    /// Core fill — adapts to the palette. White-on-dark + agent keep
    /// the BLACK core (orb has dark volume in its centre while bright
    /// rings glow around it). Black-on-light INVERTS — the core is
    /// WHITE so the orb reads as a solid object with inner light over
    /// a bright wallpaper, rather than a flat black blob.
    /// The selector is `VoiceOrbView.coreColor(for:)` for testability.
    func coreGradient(baseR: CGFloat) -> RadialGradient {
        let core = VoiceOrbView.coreColor(for: self)
        // Edge opacity tuned per palette: adaptiveBlack uses a tighter
        // (higher-opacity) edge so the white core meets the surrounding
        // black rings cleanly without a grey halo seam.
        let edgeOpacity: Double = (self == .adaptiveBlack) ? 0.85 : 0.4
        return RadialGradient(
            colors: [core, core, core.opacity(edgeOpacity)],
            center: .center,
            startRadius: 0,
            endRadius: baseR * 0.95
        )
    }

    /// Colour stops used by the static gradient ring (text-input mode).
    /// Round 4: the `pinkViolet` cycle now carries TWO pink stops
    /// (was one in round 3) so the rotating ring reads as alternating
    /// pink+violet — Maxim's "переливающийся розово-фиолетовый". A
    /// single pink slice in a 4-stop cycle read as "mostly violet
    /// with a hint of pink" once the rotation rate was slow; bumping
    /// to two pink slices distributes pink ~40% of the way around the
    /// circumference and the eye reads true shimmer regardless of
    /// where the rotation phase is at any given frame.
    var gradientRingStops: [Color] {
        switch self {
        case .pinkViolet:
            return [
                Color(red: 0.55, green: 0.36, blue: 1.0),  // indigo-violet
                Color(red: 0.97, green: 0.60, blue: 0.85), // pink (1)
                Color(red: 0.79, green: 0.55, blue: 1.0),  // light violet
                Color(red: 0.97, green: 0.60, blue: 0.85), // pink (2) — round 4 second occurrence
                Color(red: 0.55, green: 0.36, blue: 1.0)   // close cycle (indigo-violet)
            ]
        case .adaptiveWhite:
            return [.white, .white.opacity(0.6), .white, .white]
        case .adaptiveBlack:
            return [.black, .black.opacity(0.6), .black, .black]
        case .google:
            return [color1, color2, color3, color4, color1]
        }
    }
}

// MARK: - BlobShape (harmonic sum-of-sines, audio-reactive wobble)

/// Irregular wobbling polygon. Each radial step `u ∈ [0, 1]` is offset
/// by a sum of sine harmonics that take a `phase` and a `seedOffset`
/// (so each layer wobbles in its own rhythm). The polygon is sampled
/// at 220 steps, which is plenty smooth at the post-shrink ~25pt
/// diameter (60pt pre-shrink) — the
/// per-frame path cost is negligible on M-series hardware.
///
/// Audio drives a smooth voice envelope: silence pins the shape, while
/// speech slightly offsets phase and increases deformation. We avoid
/// multiplying absolute timeline phase by audio because that turns tiny
/// meter changes into huge jumps after the app has been running for a
/// while.
///
/// `freedom > 0` adds three low-frequency "sway" sines on top of the
/// harmonic stack — adapted from the reference orb's `.speaking` mode
/// — so the listening flow reads as free-flowing rather than perfectly
/// circular. Sway is deliberately subtle in the voice profile so the
/// orb does not tremble before the user speaks.
///
/// `speedGain` controls how aggressively audio accelerates the phase.
/// `0` = audio has no effect (thinking, idle). Higher = louder voice
/// reads as visibly faster harmonic motion.
///
/// `animatableData` exposes (`phase`, `audioLevel`) as an `AnimatablePair`
/// so SwiftUI's animation engine can interpolate them between frames.
struct BlobShape: Shape {
    var phase: Double
    var seedOffset: Double
    var audioLevel: Double
    var harmonics: HarmonicSet
    var freedom: Double
    /// How strongly `audioLevel` multiplies into the effective phase.
    /// Default `0` means audio is ignored — calling code that doesn't
    /// pass the profile's `speedGain` still gets a static-amplitude
    /// blob.
    var speedGain: Double

    init(
        phase: Double,
        seedOffset: Double,
        audioLevel: Double,
        harmonics: HarmonicSet,
        freedom: Double = 0,
        speedGain: Double = 0
    ) {
        self.phase = phase
        self.seedOffset = seedOffset
        self.audioLevel = audioLevel
        self.harmonics = harmonics
        self.freedom = freedom
        self.speedGain = speedGain
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, audioLevel) }
        set { phase = newValue.first; audioLevel = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let baseR = Double(min(rect.width, rect.height) / 2) * 0.96
        let steps = 220

        let clampedAudio = max(0, min(1, audioLevel))
        // Audio must not multiply absolute `phase`: `phase` is derived
        // from wall-clock time, so multiplying it by live meter values
        // creates discontinuous jumps. Add a small bounded offset
        // instead. The expression is continuous in `audioLevel` — there
        // is NO conditional teleport at any threshold. The previous
        // "if clampedAudio > threshold ? phase + ... : 0" branch was
        // exactly the jitter source Maxim flagged (room tone fluctuated
        // around the threshold, phase teleported between phase and 0).
        let effectivePhase: Double = speedGain > 0
            ? phase + clampedAudio * speedGain * 0.45
            : phase
        // In voice modes (`speedGain > 0`) BOTH wobble and sway scale
        // linearly with audio — silence is a static circle, the first
        // sound from the user lifts the deformation. In thinking
        // (`speedGain = 0`) wobble keeps its natural baseline so the
        // rigid rotation reads against an organic shape.
        let audioVisible = speedGain > 0 ? clampedAudio : 1.0
        let deformationGain = speedGain > 0 ? clampedAudio * 16.0 : 1.0

        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let a = u * .pi * 2
            var wob = 0.0
            for h in harmonics.components {
                wob += sin(a * h.k + effectivePhase * h.s + seedOffset * h.o) * h.amp * deformationGain
            }
            // Large-wavelength sway — gated by audio in voice modes (so
            // silence stays a circle), natural baseline in thinking.
            var sway = 0.0
            if freedom > 0 {
                sway =
                    (sin(a + effectivePhase * 0.35 + seedOffset * 0.7) * 0.030 +
                     sin(a * 2 - effectivePhase * 0.55 + seedOffset * 1.4) * 0.045 +
                     sin(a + effectivePhase * 0.9 + seedOffset * 2.3) * 0.022) *
                    freedom * audioVisible
            }
            // Radius is `baseR * (1 + wob + sway)` — NO audio term.
            // Quiet and loud orbs have the same bounding box; only the
            // harmonic phase is different.
            let r = baseR * (1 + wob + sway)
            let x = cx + CGFloat(cos(a) * r)
            let y = cy + CGFloat(sin(a) * r)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }
}

/// A single sinusoidal component of the wobble: angular frequency `k`,
/// phase-time scale `s`, seed-offset scale `o`, amplitude `amp`.
struct Harmonic {
    let k: Double
    let s: Double
    let o: Double
    let amp: Double
}

/// Four canned harmonic sets, one per concentric ring. Each set has a
/// distinct rhythm so the rings don't lock in phase with each other —
/// that visual independence is what makes the orb feel "alive".
struct HarmonicSet {
    let components: [Harmonic]

    static let primary = HarmonicSet(components: [
        Harmonic(k: 3, s:  1.0, o: 0.0, amp: 0.058),
        Harmonic(k: 5, s: -0.7, o: 1.3, amp: 0.032),
        Harmonic(k: 2, s:  0.5, o: 0.8, amp: 0.045)
    ])

    static let secondary = HarmonicSet(components: [
        Harmonic(k: 4, s:  0.7, o: 2.1, amp: 0.050),
        Harmonic(k: 7, s: -0.4, o: 0.7, amp: 0.024),
        Harmonic(k: 3, s:  0.3, o: 1.9, amp: 0.038)
    ])

    static let tertiary = HarmonicSet(components: [
        Harmonic(k: 5, s: -0.6, o: 3.0, amp: 0.044),
        Harmonic(k: 2, s:  0.4, o: 0.2, amp: 0.060),
        Harmonic(k: 6, s:  0.8, o: 1.1, amp: 0.027)
    ])

    static let quaternary = HarmonicSet(components: [
        Harmonic(k: 6, s: -0.9, o: 4.2, amp: 0.034),
        Harmonic(k: 3, s:  0.6, o: 2.7, amp: 0.046),
        Harmonic(k: 9, s:  0.3, o: 1.4, amp: 0.018)
    ])
}
