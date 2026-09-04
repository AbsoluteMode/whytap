import AppKit
import SwiftUI

/// Synthetic, decorative music equalizer for the right-band music wing. Five
/// rounded vertical bars animate while a track is PLAYING and settle to a calm
/// resting row when paused.
///
/// Why synthetic: a track-accurate spectrum is not available to us (Spotify's
/// audio-analysis is deprecated for new apps; Apple ships no equivalent), and
/// live per-app audio capture is blocked on this machine. Peer notch apps all
/// ship a synthetic equalizer gated on play-state — this is the same idea, a
/// touch nicer: asymmetric attack/decay (a bar snaps up, falls slow — the #1
/// realism cue) plus per-bar center-weighting so the bars do not move in
/// lockstep.
///
/// Why an `NSView` + CoreAnimation instead of a SwiftUI `TimelineView`: the
/// previous TimelineView ticked at 30 fps and, on every tick, mutated `@State`
/// which re-ran the SwiftUI body and re-laid-out the WHOLE island hosting view
/// on the main thread — ~16% CPU the entire time a track played. Here the main
/// thread only schedules ONE keyframe animation per bar per macro-cycle
/// (~0.42 s); CoreAnimation interpolates the frames on the render server, off
/// the main thread (the approach boring.notch uses). The asymmetric attack/
/// decay is preserved through keyframe timing (fast easeOut up, slow easeIn
/// down). WHY: docs/decisions/2026-06-24-island-equalizer-calayer.md
struct IslandMusicEqualizerView: NSViewRepresentable {
    /// Animate while playing; settle to the resting row when false.
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> IslandEqualizerBarsView {
        let view = IslandEqualizerBarsView()
        view.update(isPlaying: isPlaying, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: IslandEqualizerBarsView, context: Context) {
        nsView.update(isPlaying: isPlaying, reduceMotion: reduceMotion)
    }

    /// Stop the timer when SwiftUI tears the view down (e.g. a higher-priority
    /// right-band slot preempts the music wing) so no work survives off-screen.
    static func dismantleNSView(_ nsView: IslandEqualizerBarsView, coordinator: ()) {
        nsView.stop()
    }
}

/// AppKit backing view: five rounded `CAShapeLayer` bars animated entirely on
/// the CoreAnimation render server. The bars scale on `transform.scale.y` from
/// a center anchor, so they grow symmetrically about the slot's vertical
/// center — matching the old SwiftUI `HStack(alignment: .center)` layout.
final class IslandEqualizerBarsView: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var timer: Timer?
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit { timer?.invalidate() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: IslandMusicEqualizer.slotWidth, height: IslandMusicEqualizer.slotHeight)
    }

    private func configure() {
        wantsLayer = true
        layer?.masksToBounds = true // hard clip, like the old `.clipped()`
        setupBars()
    }

    private func setupBars() {
        let count = IslandMusicEqualizer.barCount
        let w = IslandMusicEqualizer.barWidth
        let spacing = IslandMusicEqualizer.barSpacing
        let h = IslandMusicEqualizer.slotHeight
        // Center the bar group inside the slot width (matches the old HStack
        // centered in `.frame(width: slotWidth)`).
        let groupWidth = CGFloat(count) * w + CGFloat(count - 1) * spacing
        let startX = (IslandMusicEqualizer.slotWidth - groupWidth) / 2

        for i in 0..<count {
            let x = startX + CGFloat(i) * (w + spacing)
            let bar = CAShapeLayer()
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            bar.path = CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
            bar.fillColor = NSColor.white
                .withAlphaComponent(CGFloat(IslandMusicEqualizer.barOpacity)).cgColor
            bar.bounds = rect
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: x + w / 2, y: h / 2)
            bar.transform = CATransform3DMakeScale(
                1, IslandMusicEqualizer.barScaleY(normalized: IslandMusicEqualizer.floors[i]), 1
            )
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    func update(isPlaying: Bool, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        if isPlaying && !reduceMotion {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard timer == nil else { return }
        tick() // kick immediately so the row comes alive without a cycle's delay
        let t = Timer(timeInterval: IslandMusicEqualizer.cycleDuration, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // `.common` so the bars keep moving during scrolls / event tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settleToFloors()
    }

    /// One macro-cycle: snap each bar UP to a fresh target fast, then ease it
    /// DOWN to its floor slowly — the asymmetric VU-meter cue, expressed as a
    /// single keyframe animation per bar that the render server interpolates.
    private func tick() {
        let targets = IslandMusicEqualizer.randomTargets(count: barLayers.count)
        for (i, bar) in barLayers.enumerated() {
            let floorScale = IslandMusicEqualizer.barScaleY(normalized: IslandMusicEqualizer.floors[i])
            let peakScale = IslandMusicEqualizer.barScaleY(normalized: targets[i])
            let current = (bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? floorScale

            let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
            anim.values = [current, peakScale, floorScale]
            anim.keyTimes = [0, NSNumber(value: IslandMusicEqualizer.attackFraction), 1]
            anim.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut), // fast attack
                CAMediaTimingFunction(name: .easeIn)   // slow decay
            ]
            anim.duration = IslandMusicEqualizer.cycleDuration
            if #available(macOS 13.0, *) {
                anim.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            }
            // Settle the model value on the floor so the bar rests low between
            // cycles once the (auto-removed) animation completes.
            bar.transform = CATransform3DMakeScale(1, floorScale, 1)
            bar.add(anim, forKey: "eq")
        }
    }

    private func settleToFloors() {
        for (i, bar) in barLayers.enumerated() {
            let floorScale = IslandMusicEqualizer.barScaleY(normalized: IslandMusicEqualizer.floors[i])
            let current = (bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? floorScale
            bar.removeAnimation(forKey: "eq")
            let anim = CABasicAnimation(keyPath: "transform.scale.y")
            anim.fromValue = current
            anim.toValue = floorScale
            anim.duration = 0.3
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.transform = CATransform3DMakeScale(1, floorScale, 1)
            bar.add(anim, forKey: "settle")
        }
    }
}

/// Visual + dynamics constants for the synthetic equalizer. The slot matches
/// the wing's waveform envelope (`IslandMusicWing.waveformWidth` ×
/// `IslandMusicWing.topHeight` = 30 × 17). Five bars + their gaps fit inside the
/// 30 pt width; `masksToBounds` is the hard guarantee nothing paints outside.
enum IslandMusicEqualizer {
    static let barCount = 5
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2.25 // 5*3 + 4*2.25 = 24 pt, inside the 30 pt slot
    static let minBarHeight: CGFloat = 2
    static let barOpacity: Double = 0.82 // matches the wing's progress-fill white

    static let slotWidth = IslandMusicWing.waveformWidth // 30
    static let slotHeight = IslandMusicWing.topHeight     // 17

    /// One macro-cycle: a bar snaps to its fresh target then eases back to its
    /// floor. The render server interpolates the frames in between.
    static let cycleDuration: TimeInterval = 0.42
    /// Fraction of a cycle spent rising (fast attack); the rest is the slow
    /// decay — the asymmetric envelope.
    static let attackFraction: Double = 0.22

    /// Distinct per-bar resting heights so the at-rest row reads as a shaped
    /// silhouette (center a touch taller) rather than a flat line.
    static let floors: [Double] = [0.24, 0.34, 0.40, 0.32, 0.22]

    /// Center-weighted scale in `(0, 1]`: center bars peak at full height, edge
    /// bars a touch lower. Deterministic per-bar difference that, combined with
    /// the random base, breaks lockstep without looking erratic.
    static func centerBoost(forBar index: Int, count: Int) -> Double {
        guard count > 1 else { return 1.0 }
        let half = Double(count - 1) / 2.0
        let distanceFromCenter = abs(Double(index) - half) / half // 0 center … 1 edge
        return 1.0 - distanceFromCenter * 0.22 // 1.0 center … ~0.78 edge
    }

    /// Fresh per-bar targets in `0...1`, center-weighted so the middle bars
    /// trend a touch taller without ever pinning.
    static func randomTargets(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let base = Double.random(in: 0.25...1.0)
            return min(1.0, base * centerBoost(forBar: index, count: count))
        }
    }

    /// Map a normalized bar height (`0...1`) to its layer Y-scale, floored so a
    /// resting bar still paints a visible sliver and clamped at full height.
    static func barScaleY(normalized: Double) -> CGFloat {
        let minScale = minBarHeight / slotHeight
        return min(1.0, max(minScale, CGFloat(normalized)))
    }
}
