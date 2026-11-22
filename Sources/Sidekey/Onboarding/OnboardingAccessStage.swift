import AppKit
import SwiftUI

// The access steps (the design pass's screen 04, approved 2026-11-22): one
// template for Keyboard control, Microphone, Input Monitoring and Screen
// Recording. Each has its own wire figure in the key, padlock and globe
// family: a ⌘ keycap on its switch stem, a microphone capsule on its yoke,
// an aperture, a display with viewfinder corners. Rest: the purpose and
// Allow. Waiting: where to turn Whytap on, with a quiet Open System Settings
// and no spinner. Allowed: the figure plays its click and the step flows on.
// Not on yet: one calm line and Allow again. Only the system's own check
// moves a step on.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

/// The four access steps and their words.
enum OnboardingAccessKind: CaseIterable {
    case keyboard, microphone, inputMonitoring, screenRecording

    init?(step: OnboardingStep) {
        switch step {
        case .keyboard: self = .keyboard
        case .microphone: self = .microphone
        case .inputMonitoring: self = .inputMonitoring
        case .screenRecording: self = .screenRecording
        default: return nil
        }
    }

    var step: OnboardingStep {
        switch self {
        case .keyboard: return .keyboard
        case .microphone: return .microphone
        case .inputMonitoring: return .inputMonitoring
        case .screenRecording: return .screenRecording
        }
    }

    var title: String {
        switch self {
        case .keyboard: return "Keyboard control."
        case .microphone: return "Microphone."
        case .inputMonitoring: return "Input Monitoring."
        case .screenRecording: return "Screen Recording."
        }
    }

    var purpose: String {
        switch self {
        case .keyboard: return "To hear your Drop shortcut and type the text where your cursor is."
        case .microphone: return "To hear you, only while Drop is recording."
        case .inputMonitoring: return "This Mac also asks for it before Drop can see its shortcut."
        case .screenRecording: return "Optional. For Shot, and when you ask the Agent about your screen."
        }
    }

    /// The pane under Privacy & Security.
    var pane: String {
        switch self {
        case .keyboard: return "Accessibility"
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    var grantedLine: String {
        switch self {
        case .keyboard: return "Ready to type anywhere."
        case .microphone: return "Drop can hear you now."
        case .inputMonitoring: return "Drop can see its shortcut."
        case .screenRecording: return "Ready for Shot and the Agent."
        }
    }

    var notOnLine: String {
        switch self {
        case .keyboard: return "Whytap isn’t on in Accessibility yet."
        case .microphone: return "Microphone access is still off."
        case .inputMonitoring: return "Input Monitoring isn’t on yet."
        case .screenRecording: return "Screen Recording isn’t on yet."
        }
    }

    var isOptional: Bool { self == .screenRecording }
}

// MARK: - Figures

/// The four wire figures, in the prototype's model space (y grows down).
enum OnboardingAccessFigures {
    typealias Vec3 = OnboardingWireSolid.Vec3

    /// Collects one part's vertices in the figure's shared unit scale.
    struct Builder {
        let norm: Double
        let shift: Double
        private(set) var vertices: [Vec3] = []
        private(set) var edges: [(Int, Int)] = []
        private(set) var dots: [Int] = []
        private var seen = Set<Int>()

        init(norm: Double, shift: Double) {
            self.norm = norm
            self.shift = shift
        }

        mutating func point(_ x: Double, _ y: Double, _ z: Double, dot: Bool = false) -> Int {
            vertices.append(Vec3(x: x * norm, y: (y + shift) * norm, z: z * norm))
            if dot { dots.append(vertices.count - 1) }
            return vertices.count - 1
        }

        mutating func edge(_ a: Int, _ b: Int) {
            let key = min(a, b) * 100_000 + max(a, b)
            guard seen.insert(key).inserted else { return }
            edges.append((a, b))
        }

        var solid: OnboardingWireSolid { OnboardingWireSolid(normalized: vertices, edges: edges, dotIndices: dots) }
    }

    /// The ⌘ glyph in a keycap's (x, z) plane: the square's sides run on
    /// into four 270-degree loops that meet them at their tangents, as the
    /// glyph does.
    static func commandGlyph(side: Double, loop: Double, segments: Int = 14) -> [[(Double, Double)]] {
        let reach = side + loop
        var strokes: [[(Double, Double)]] = [
            [(-side, -reach), (-side, reach)], [(side, -reach), (side, reach)],
            [(-reach, -side), (reach, -side)], [(-reach, side), (reach, side)],
        ]
        for (sx, sz) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
            let cx = sx * reach, cz = sz * reach
            let start = atan2(0, -sx), end = atan2(-sz, 0)
            var delta = end - start
            while delta <= -.pi { delta += 2 * .pi }
            while delta > .pi { delta -= 2 * .pi }
            // The long way round, away from the square.
            let sweep = delta > 0 ? delta - 2 * .pi : delta + 2 * .pi
            strokes.append((0...segments).map { s in
                let a = start + sweep * Double(s) / Double(segments)
                return (cx + cos(a) * loop, cz + sin(a) * loop)
            })
        }
        return strokes
    }

    static func octagon(_ w: Double, _ chamfer: Double) -> [(Double, Double)] {
        [(-w + chamfer, -w), (w - chamfer, -w), (w, -w + chamfer), (w, w - chamfer),
         (w - chamfer, w), (-w + chamfer, w), (-w, w - chamfer), (-w, -w + chamfer)]
    }

    // MARK: Keyboard control: a ⌘ keycap on its switch

    enum Keyboard {
        static let norm = 1 / 0.90, shift = -0.06

        /// The switch housing and its cross stem.
        static let base: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: shift)
            let top = octagon(0.68, 0.14).map { b.point($0.0, 0.34, $0.1, dot: true) }
            let bottom = octagon(0.68, 0.14).map { b.point($0.0 * 0.95, 0.48, $0.1 * 0.95) }
            for i in 0..<8 {
                b.edge(top[i], top[(i + 1) % 8])
                b.edge(bottom[i], bottom[(i + 1) % 8])
                if i % 2 == 0 { b.edge(top[i], bottom[i]) }
            }
            let y0 = 0.04, y1 = 0.34, arm = 0.15
            b.edge(b.point(-arm, y0, 0, dot: true), b.point(arm, y0, 0, dot: true))
            b.edge(b.point(0, y0, -arm, dot: true), b.point(0, y0, arm, dot: true))
            b.edge(b.point(-arm, y1, 0), b.point(arm, y1, 0))
            b.edge(b.point(0, y1, -arm), b.point(0, y1, arm))
            for (x, z) in [(-arm, 0.0), (arm, 0), (0, -arm), (0, arm)] {
                b.edge(b.point(x, y0, z), b.point(x, y1, z))
            }
            return b.solid
        }()

        static let dishY = -0.24

        /// The sculpted keycap: skirt, dish and the homing bar.
        static let cap: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: shift)
            let skirt = octagon(0.62, 0.13).map { b.point($0.0, 0.20, $0.1, dot: true) }
            let dish = octagon(0.45, 0.10).enumerated().map { index, p in
                // A gentle finger scoop across the dish.
                b.point(p.0, dishY + ([0, 1, 4, 5].contains(index) ? 0.025 : 0), p.1, dot: true)
            }
            for i in 0..<8 {
                b.edge(skirt[i], skirt[(i + 1) % 8])
                b.edge(dish[i], dish[(i + 1) % 8])
                b.edge(skirt[i], dish[i])
            }
            b.edge(b.point(-0.13, dishY + 0.02, 0.33, dot: true), b.point(0.13, dishY + 0.02, 0.33, dot: true))
            return b.solid
        }()

        /// The ⌘ legend, drawn as clean strokes on the dish (sharper than
        /// the prototype's): the square's sides run on into four 270° loops
        /// that meet them at their tangents, as the glyph does.
        static let legend: [[Vec3]] = {
            let y = dishY - 0.006
            return commandGlyph(side: 0.085, loop: 0.072).map { stroke in
                stroke.map { Vec3(x: $0.0 * norm, y: (y + shift) * norm, z: $0.1 * norm) }
            }
        }()

        /// The text caret that rises beside the key once it is allowed.
        static let caret: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: shift)
            let x = 0.74, z = -0.18, y0 = -0.52, y1 = 0.04, bar = 0.10
            b.edge(b.point(x, y0, z), b.point(x, y1, z))
            b.edge(b.point(x - bar, y0, z, dot: true), b.point(x + bar, y0, z, dot: true))
            b.edge(b.point(x - bar, y1, z, dot: true), b.point(x + bar, y1, z, dot: true))
            return b.solid
        }()
    }

    // MARK: Microphone: a capsule on its yoke

    enum Microphone {
        static let norm = 1 / 0.90, shift = -0.06

        static let yoke: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: shift)
            let ring = (0..<12).map { i -> Int in
                let a = Double(i) / 12 * 2 * .pi
                return b.point(0.38 * cos(a), 0.74, 0.38 * sin(a), dot: i % 3 == 0)
            }
            for i in 0..<12 { b.edge(ring[i], ring[(i + 1) % 12]) }
            b.edge(b.point(0, 0.74, 0, dot: true), b.point(0, 0.50, 0, dot: true))
            let arc = (0...10).map { s -> Int in
                let a = Double.pi * Double(s) / 10
                return b.point(0.44 * cos(a), 0.08 + 0.42 * sin(a), 0, dot: s == 0 || s == 10)
            }
            for s in 0..<10 { b.edge(arc[s], arc[s + 1]) }
            b.edge(b.point(0.44, 0.08, 0, dot: true), b.point(0.32, 0.08, 0))
            b.edge(b.point(-0.44, 0.08, 0, dot: true), b.point(-0.32, 0.08, 0))
            return b.solid
        }()

        /// The capsule's body and its grille dome.
        static let capsule: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: shift)
            let segments = 12, r = 0.28
            var bottom: [Int] = [], middle: [Int] = [], collar: [Int] = []
            for i in 0..<segments {
                let a = Double(i) / Double(segments) * 2 * .pi
                bottom.append(b.point(r * 0.90 * cos(a), 0.36, r * 0.90 * sin(a), dot: i % 3 == 0))
                middle.append(b.point(r * cos(a), -0.02, r * sin(a), dot: i % 2 == 0))
                collar.append(b.point(r * 1.07 * cos(a), -0.07, r * 1.07 * sin(a)))
            }
            for i in 0..<segments {
                let n = (i + 1) % segments
                b.edge(bottom[i], bottom[n]); b.edge(middle[i], middle[n]); b.edge(collar[i], collar[n])
                if i % 2 == 0 { b.edge(bottom[i], middle[i]) }
            }
            for lat in [0.45, 0.85] {
                let rl = r * cos(lat), yl = -0.07 - 0.48 * sin(lat)
                let ring = (0..<segments).map { i -> Int in
                    let a = Double(i) / Double(segments) * 2 * .pi
                    return b.point(rl * cos(a), yl, rl * sin(a))
                }
                for i in 0..<segments { b.edge(ring[i], ring[(i + 1) % segments]) }
            }
            let crown = b.point(0, -0.55, 0, dot: true)
            for m in 0..<6 {
                let a = Double(m) / 6 * .pi
                var previous: Int?
                for s in 0...8 {
                    let th = -Double.pi / 2 + Double(s) / 8 * .pi
                    let index = s == 4 ? crown
                        : b.point(r * sin(th) * cos(a), -0.07 - 0.48 * cos(th), r * sin(th) * sin(a))
                    if let previous { b.edge(previous, index) }
                    previous = index
                }
            }
            return b.solid
        }()

        /// Two sound rings that bloom once it is allowed.
        static let waves: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: shift)
            for (ringIndex, radius) in [0.54, 0.78].enumerated() {
                let ring = (0..<24).map { i -> Int in
                    let a = Double(i) / 24 * 2 * .pi
                    return b.point(radius * cos(a), -0.26 + sin(a * 4) * 0.035, radius * sin(a),
                                   dot: i % 6 == 0 && ringIndex == 0)
                }
                for i in 0..<24 { b.edge(ring[i], ring[(i + 1) % 24]) }
            }
            return b.solid
        }()
    }

    // MARK: Input Monitoring: an aperture

    enum Iris {
        static let norm = 1 / 0.88

        static let housing: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: 0)
            let segments = 12, outer = 0.76, inner = 0.60, depth = 0.095
            var fo: [Int] = [], bo: [Int] = [], fi: [Int] = [], bi: [Int] = []
            for i in 0..<segments {
                let a = Double(i) / Double(segments) * 2 * .pi
                fo.append(b.point(outer * cos(a), outer * sin(a), depth, dot: i % 2 == 0))
                bo.append(b.point(outer * cos(a), outer * sin(a), -depth))
                fi.append(b.point(inner * cos(a), inner * sin(a), depth * 0.7, dot: i % 2 == 1))
                bi.append(b.point(inner * cos(a), inner * sin(a), -depth * 0.7))
            }
            for i in 0..<segments {
                let n = (i + 1) % segments
                b.edge(fo[i], fo[n]); b.edge(bo[i], bo[n]); b.edge(fi[i], fi[n]); b.edge(bi[i], bi[n])
                if i % 2 == 0 { b.edge(fo[i], bo[i]); b.edge(fo[i], fi[i]) }
            }
            return b.solid
        }()

        /// Six blades; each tip moves as the aperture opens.
        static let blades: (solid: OnboardingWireSolid, tips: [(index: Int, angle: Double)]) = {
            var b = Builder(norm: norm, shift: 0)
            var tips: [(Int, Double)] = []
            for blade in 0..<6 {
                let a = Double(blade) / 6 * 2 * .pi
                let p0 = b.point(0.58 * cos(a), 0.58 * sin(a), 0.02)
                let p1 = b.point(0.58 * cos(a + 0.52), 0.58 * sin(a + 0.52), 0.02)
                let tip = b.point(0.20 * cos(a + 0.85), 0.20 * sin(a + 0.85), 0.02, dot: true)
                b.edge(p0, tip); b.edge(p1, tip); b.edge(p0, p1)
                tips.append((tip, a))
            }
            return (b.solid, tips.map { (index: $0.0, angle: $0.1) })
        }()

        /// The signal core in the pupil, larger once allowed.
        static let core: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: 0)
            let r = 0.20
            let p = [b.point(r, 0, 0, dot: true), b.point(-r, 0, 0, dot: true), b.point(0, r, 0, dot: true),
                     b.point(0, -r, 0, dot: true), b.point(0, 0, r * 1.4, dot: true), b.point(0, 0, -r * 1.4, dot: true)]
            for (x, y) in [(0, 2), (2, 1), (1, 3), (3, 0), (0, 4), (2, 4), (1, 4), (3, 4), (0, 5), (2, 5), (1, 5), (3, 5)] {
                b.edge(p[x], p[y])
            }
            return b.solid
        }()
    }

    // MARK: Screen Recording: a display and viewfinder corners

    enum Screen {
        static let norm = 1 / 0.92, shift = -0.04

        static let display: OnboardingWireSolid = {
            var b = Builder(norm: norm, shift: shift)
            let w = 0.74, top = -0.50, bottom = 0.38, z = 0.042, ch = 0.07
            let outline: [(Double, Double)] = [(-w + ch, top), (w - ch, top), (w, top + ch), (w, bottom - ch),
                                               (w - ch, bottom), (-w + ch, bottom), (-w, bottom - ch), (-w, top + ch)]
            let front = outline.map { b.point($0.0, $0.1, z, dot: true) }
            let back = outline.map { b.point($0.0, $0.1, -z) }
            for i in 0..<8 {
                b.edge(front[i], front[(i + 1) % 8]); b.edge(back[i], back[(i + 1) % 8])
                if i % 2 == 0 { b.edge(front[i], back[i]) }
            }
            // The screen and the camera notch.
            let l = -0.65, r = 0.65, t = -0.41, btm = 0.29
            let bl = b.point(l, btm, z), br = b.point(r, btm, z), tl = b.point(l, t, z), tr = b.point(r, t, z)
            let n1 = b.point(-0.11, t, z), n2 = b.point(-0.095, t + 0.055, z)
            let n3 = b.point(0.095, t + 0.055, z), n4 = b.point(0.11, t, z)
            b.edge(bl, br); b.edge(br, tr); b.edge(tl, bl)
            b.edge(tl, n1); b.edge(n1, n2); b.edge(n2, n3); b.edge(n3, n4); b.edge(n4, tr)
            // A window on the screen.
            let w0 = b.point(-0.36, -0.20, z), w1 = b.point(0.36, -0.20, z)
            let w2 = b.point(0.36, 0.14, z), w3 = b.point(-0.36, 0.14, z)
            b.edge(w0, w1); b.edge(w1, w2); b.edge(w2, w3); b.edge(w3, w0)
            // The stand.
            let s1 = b.point(-0.11, bottom, -0.02), s2 = b.point(0.11, bottom, -0.02)
            let s3 = b.point(-0.15, 0.62, -0.08, dot: true), s4 = b.point(0.15, 0.62, -0.08, dot: true)
            let f1 = b.point(-0.24, 0.64, 0.14, dot: true), f2 = b.point(0.24, 0.64, 0.14, dot: true)
            b.edge(s1, s3); b.edge(s2, s4); b.edge(s3, s4); b.edge(s3, f1); b.edge(s4, f2); b.edge(f1, f2)
            return b.solid
        }()

        /// Four viewfinder corners: outside the display at rest, on the
        /// window once allowed. Each vertex knows its corner's direction.
        static let brackets: (solid: OnboardingWireSolid, corners: [(index: Int, sx: Double, sy: Double)]) = {
            var b = Builder(norm: norm, shift: shift)
            var corners: [(Int, Double, Double)] = []
            let bx = 0.44, top = -0.26, bottom = 0.20, leg = 0.16, z = 0.16
            for (sx, sy, x, y) in [(-1.0, -1.0, -bx, top), (1, -1, bx, top), (1, 1, bx, bottom), (-1, 1, -bx, bottom)] {
                let corner = b.point(x, y, z, dot: true)
                let horizontal = b.point(x - sx * leg, y, z, dot: true)
                let vertical = b.point(x, y - sy * leg, z, dot: true)
                b.edge(corner, horizontal); b.edge(corner, vertical)
                corners += [(corner, sx, sy), (horizontal, sx, sy), (vertical, sx, sy)]
            }
            return (b.solid, corners.map { (index: $0.0, sx: $0.1, sy: $0.2) })
        }()
    }
}

// MARK: - Motion

/// The figure's springs, stepped per frame like the prototype: the click
/// when a step is allowed (with its overshoot), the new figure coming
/// forward along depth, the small turn when System Settings opens, and the
/// slow sway.
final class OnboardingAccessMotion {
    /// Offscreen renders and tests: every spring lands at once.
    static var settlesAtOnce = false

    private(set) var clock = 1.0
    private(set) var actuate = OnboardingSpring(0)
    private(set) var stage = OnboardingSpring(-0.35)
    private(set) var kick = OnboardingSpring(0)
    private var last: TimeInterval?
    private var pressed = false

    var still: Bool { Self.settlesAtOnce }

    /// "Open System Settings": a small turn of the figure.
    func nudge() { kick.velocity += 0.35 }

    func advance(to time: TimeInterval, reduceMotion: Bool, granted: Bool) {
        let still = reduceMotion || Self.settlesAtOnce
        let first = last == nil
        let dt = min(0.04, last.map { max(0, time - $0) } ?? 0.016)
        last = time
        if !still { clock += dt }
        // The click plays when the switch turns on here, not when a step
        // that was already allowed is shown again.
        if first, granted { actuate = OnboardingSpring(1) }
        if granted, !pressed, !still, !first { actuate.velocity += 2.2 }
        pressed = granted
        actuate.step(to: granted ? 1 : 0, stiffness: 210, damping: 13.5, dt: dt, still: still)
        if still {
            stage = OnboardingSpring(0)
        } else {
            stage.value += (0 - stage.value) * (1 - exp(-dt * 9))
        }
        kick.step(to: 0, stiffness: 200, damping: 14, dt: dt, still: still)
    }
}

// MARK: - The figure

/// Draws the step's figure: one Canvas per display frame.
struct OnboardingAccessFigure: View {
    let kind: OnboardingAccessKind
    let state: OnboardingAccessState
    let motion: OnboardingAccessMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let radius = 58.0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                motion.advance(to: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion,
                               granted: state == .granted)
                draw(in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var still: Bool { reduceMotion || OnboardingAccessMotion.settlesAtOnce }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let clock = motion.clock
        let bob = still ? 0 : sin(clock * 0.72) * 1.8
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + bob)
        let worldZ = motion.stage.value
        let fade = max(0.15, min(1, 1 + worldZ * 1.4))
        let sway = (y: (still ? 0 : sin(clock * 0.54) * 0.11) + motion.kick.value * 0.25,
                    x: still ? 0 : cos(clock * 0.42) * 0.055)
        let act = max(-0.15, min(1.35, motion.actuate.value))
        let open = max(0, min(1, act))
        let r = Self.radius

        var tint = OnboardingWireframeInk.rose, strength = 0.56
        switch state {
        case .rest: break
        case .waiting: strength = 0.86
        case .granted: tint = OnboardingWireframeInk.green; strength = 0.90
        case .notOn: tint = OnboardingWireframeInk.amber; strength = 0.80
        }
        // While it waits, a light runs up the figure.
        let waveY: Double? = state == .waiting && !still
            ? center.y + 50 - (clock * 62).truncatingRemainder(dividingBy: 106) : nil
        let light = (x: 0.44 + sin(clock * 0.58) * 0.14, y: -0.52 + cos(clock * 0.46) * 0.12, z: 0.72)
        func style(_ fade: Double, _ strength: Double, wave: Bool = true) -> OnboardingWireStyle {
            OnboardingWireStyle(fade: fade, specular: .init(rgb: tint, strength: strength, light: light, dots: true,
                                                             waveY: wave ? waveY : nil),
                                keyStage: true)
        }
        func moved(_ solid: OnboardingWireSolid, _ change: (Int, OnboardingWireSolid.Vec3) -> OnboardingWireSolid.Vec3)
            -> [Int: OnboardingWireSolid.Vec3] {
            var result: [Int: OnboardingWireSolid.Vec3] = [:]
            for (i, v) in solid.vertices.enumerated() { result[i] = change(i, v) }
            return result
        }

        switch kind {
        case .keyboard:
            typealias K = OnboardingAccessFigures.Keyboard
            let angles = (ax: -0.48 + sway.x, ay: -0.54 + sway.y, az: 0.04)
            K.base.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                        style: style(fade * 0.88, strength * 0.75))
            // The cap goes down onto its stem when allowed.
            let press = act * 0.16 * K.norm
            K.cap.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                       style: style(fade, strength), moved: moved(K.cap) { _, v in .init(x: v.x, y: v.y + press, z: v.z) })
            OnboardingWireStrokes.draw(K.legend, in: &context, center: center, radius: r, worldZ: worldZ, angles: angles,
                                       lift: press, fade: fade, tint: tint)
            if act > 0.08 {
                let lift = (1 - min(1, act)) * 0.18
                K.caret.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                             style: style(min(1, (act - 0.08) / 0.65) * fade, 1, wave: false),
                             moved: moved(K.caret) { _, v in .init(x: v.x, y: v.y + lift, z: v.z) })
            }
        case .microphone:
            typealias M = OnboardingAccessFigures.Microphone
            let angles = (ax: -0.22 + sway.x, ay: -0.48 + sway.y, az: 0.03)
            M.yoke.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                        style: style(fade * 0.9, strength * 0.75))
            // The capsule tilts upright when allowed.
            let tilt = (1 - open) * 0.24
            M.capsule.draw(in: &context, center: center, worldZ: worldZ, radius: r,
                           angles: (ax: angles.ax - tilt, ay: angles.ay, az: angles.az), style: style(fade, strength))
            if act > 0.08 {
                let scale = 0.72 + 0.28 * act
                M.waves.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                             style: style(min(1, (act - 0.08) / 0.65) * fade * 0.85, 1, wave: false),
                             moved: moved(M.waves) { _, v in .init(x: v.x * scale, y: v.y, z: v.z * scale) })
            }
        case .inputMonitoring:
            typealias I = OnboardingAccessFigures.Iris
            let roll = still ? 0 : clock * 0.12
            let angles = (ax: -0.20 + sway.x, ay: -0.40 + sway.y, az: 0.04 + roll * 0.25)
            I.housing.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                           style: style(fade * 0.92, strength * 0.8))
            // The blades open.
            let inner = 0.19 + open * 0.27, twist = 0.85 - open * 0.36
            var tips: [Int: OnboardingWireSolid.Vec3] = [:]
            for tip in I.blades.tips {
                let v = I.blades.solid.vertices[tip.index]
                tips[tip.index] = .init(x: inner * cos(tip.angle + twist) * I.norm, y: inner * sin(tip.angle + twist) * I.norm, z: v.z)
            }
            I.blades.solid.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                                style: style(fade, strength), moved: tips)
            let scale = 0.55 + open * 0.65
            I.core.draw(in: &context, center: center, worldZ: worldZ, radius: r,
                        angles: (ax: angles.ax, ay: angles.ay + (still ? 0 : clock * 0.6), az: 0.04),
                        style: style(fade * (0.45 + 0.55 * open), 1),
                        moved: moved(I.core) { _, v in .init(x: v.x * scale, y: v.y * scale, z: v.z * scale) })
        case .screenRecording:
            typealias S = OnboardingAccessFigures.Screen
            let angles = (ax: -0.18 + sway.x, ay: -0.42 + sway.y, az: 0.02)
            S.display.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                           style: style(fade * 0.92, strength * 0.8))
            // The corners close in on the window when allowed.
            let breathe = still ? 0 : sin(clock * 1.4)
            let spreadX = (1 - open) * 0.44 + breathe * 0.015, spreadY = (1 - open) * 0.34 + breathe * 0.012
            var corners: [Int: OnboardingWireSolid.Vec3] = [:]
            for corner in S.brackets.corners {
                let v = S.brackets.solid.vertices[corner.index]
                corners[corner.index] = .init(x: v.x + corner.sx * spreadX * S.norm, y: v.y + corner.sy * spreadY * S.norm,
                                              z: v.z - open * 0.09 * S.norm)
            }
            S.brackets.solid.draw(in: &context, center: center, worldZ: worldZ, radius: r, angles: angles,
                                  style: style(fade, strength * 1.05), moved: corners)
        }
    }
}

// MARK: - The step

/// One access step: the title, its figure, one line of copy, the Allow
/// capsule and, under it, the quiet links.
struct OnboardingAccessStage: View {
    let kind: OnboardingAccessKind
    @ObservedObject var model: OnboardingJourneyModel
    /// Offscreen renders show a state without asking the system.
    var shownState: OnboardingAccessState?
    @State private var motion = OnboardingAccessMotion()

    private var state: OnboardingAccessState { shownState ?? model.accessState(kind.step) }

    var body: some View {
        VStack(spacing: 0) {
            Text(kind.title)
                .font(OnboardingTheme.serifItalic(31))
                .foregroundColor(OnboardingTheme.ink)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            OnboardingAccessFigure(kind: kind, state: state, motion: motion)
                .frame(height: 138)
            copy
                .frame(height: 46, alignment: .top)
                .padding(.horizontal, 36)
            OnboardingAccessPill(kind: kind, state: state) {
                switch state {
                case .rest, .notOn: model.requestAccess(kind.step)
                case .waiting: model.recheckPermissions()
                case .granted: break
                }
            }
            .padding(.top, 4)
            links
                .frame(height: 30)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckPermissions()
        }
    }

    @ViewBuilder private var copy: some View {
        switch state {
        case .rest:
            line(kind.purpose, color: OnboardingTheme.muted)
        case .waiting:
            VStack(spacing: 5) {
                (Text("Turn on ") + Text("Whytap").fontWeight(.semibold).foregroundColor(OnboardingTheme.ink)
                    + Text(", then come back here."))
                    .font(OnboardingTheme.sans(13.5))
                    .foregroundColor(OnboardingTheme.muted)
                HStack(spacing: 7) {
                    Text("Privacy & Security")
                    Text("›").foregroundColor(OnboardingTheme.faint)
                    Text(kind.pane)
                }
                .font(OnboardingTheme.sans(13.5, weight: .semibold))
                .foregroundColor(OnboardingTheme.ink)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Privacy and Security, \(kind.pane)")
            }
            .multilineTextAlignment(.center)
        case .granted:
            line(kind.grantedLine, color: OnboardingWireframeInk.greenColor)
        case .notOn:
            line(kind.notOnLine, color: OnboardingWireframeInk.amberColor)
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(OnboardingTheme.sans(13.5))
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var links: some View {
        HStack(spacing: 14) {
            if state == .waiting {
                OnboardingWireLink(title: "Open System Settings", arrow: "arrow.up.right") {
                    motion.nudge()
                    model.openSystemSettings(for: kind.step)
                }
            }
            if kind.isOptional, state != .granted {
                OnboardingWireLink(title: "Skip for now", arrow: "arrow.right", action: model.next)
            }
        }
    }
}

/// The access step's capsule: Allow →, Waiting… (no
/// spinner), Allowed ✓, Allow again →.
struct OnboardingAccessPill: View {
    let kind: OnboardingAccessKind
    let state: OnboardingAccessState
    let action: () -> Void

    var body: some View {
        switch state {
        case .rest:
            OnboardingWirePill("Allow", isDefault: true, action: action).accessibilityLabel("Allow \(kind.pane)")
        case .waiting:
            OnboardingWirePill("Waiting…", tone: .active, disc: .none, action: action)
        case .granted:
            OnboardingWirePill("Allowed", tone: .done, disc: .check, action: {})
        case .notOn:
            OnboardingWirePill("Allow again", tone: .warn, isDefault: true, action: action)
        }
    }
}
