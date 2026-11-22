import SwiftUI

// The wire figures of the last three steps (design pass screens 05 to 09), in
// the key, padlock and globe family: keycaps with a crisp legend and the
// line that turns into voice waves.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

/// The glyph drawn on a keycap's dish.
enum OnboardingKeycapLegend: Equatable {
    case none, option, command, shift
}

/// A sculpted keycap on its switch, as on the access step, with its legend.
struct OnboardingKeycapFigure {
    typealias Vec3 = OnboardingWireSolid.Vec3

    let base: OnboardingWireSolid
    let cap: OnboardingWireSolid
    let legend: [[Vec3]]
    let norm: Double

    init(_ glyph: OnboardingKeycapLegend, offsetX ox: Double = 0, offsetZ oz: Double = 0, scale: Double = 1) {
        let norm = 1 / 0.90 * scale
        self.norm = norm
        typealias Builder = OnboardingAccessFigures.Builder
        var b = Builder(norm: norm, shift: 0)
        let plate = OnboardingAccessFigures.octagon(0.66, 0.14)
        let top = plate.map { b.point($0.0 + ox, 0.34, $0.1 + oz, dot: true) }
        let bottom = plate.map { b.point($0.0 * 0.95 + ox, 0.47, $0.1 * 0.95 + oz) }
        for i in 0..<8 {
            b.edge(top[i], top[(i + 1) % 8])
            b.edge(bottom[i], bottom[(i + 1) % 8])
            if i % 2 == 0 { b.edge(top[i], bottom[i]) }
        }
        b.edge(b.point(-0.14 + ox, 0.05, oz, dot: true), b.point(0.14 + ox, 0.05, oz, dot: true))
        b.edge(b.point(ox, 0.05, -0.14 + oz, dot: true), b.point(ox, 0.05, 0.14 + oz, dot: true))
        base = b.solid

        var c = Builder(norm: norm, shift: 0)
        let dishY = -0.23
        let skirt = OnboardingAccessFigures.octagon(0.61, 0.13).map { c.point($0.0 + ox, 0.20, $0.1 + oz, dot: true) }
        let dish = OnboardingAccessFigures.octagon(0.45, 0.10).enumerated().map { index, p in
            c.point(p.0 + ox, dishY + ([0, 1, 4, 5].contains(index) ? 0.024 : 0), p.1 + oz, dot: true)
        }
        for i in 0..<8 {
            c.edge(skirt[i], skirt[(i + 1) % 8])
            c.edge(dish[i], dish[(i + 1) % 8])
            c.edge(skirt[i], dish[i])
        }
        cap = c.solid

        let y = dishY - 0.006
        func v(_ x: Double, _ z: Double) -> Vec3 { Vec3(x: (x + ox) * norm, y: y * norm, z: (z + oz) * norm) }
        switch glyph {
        case .none:
            legend = []
        case .option:
            legend = [[v(-0.22, -0.11), v(-0.06, -0.11), v(0.08, 0.12), v(0.23, 0.12)], [v(0.06, -0.11), v(0.23, -0.11)]]
        case .shift:
            legend = [[v(0, -0.18), v(-0.20, 0.01), v(-0.08, 0.01), v(-0.08, 0.16), v(0.08, 0.16), v(0.08, 0.01),
                       v(0.20, 0.01), v(0, -0.18)]]
        case .command:
            legend = OnboardingAccessFigures.commandGlyph(side: 0.085, loop: 0.072).map { $0.map { v($0.0, $0.1) } }
        }
    }

    /// The cap goes down onto its stem by `press` (0 rest, 1 pressed).
    func draw(in context: inout GraphicsContext, center: CGPoint, radius: Double, angles: (ax: Double, ay: Double, az: Double),
              worldZ: Double, press: Double, fade: Double, tint: OnboardingWireframeInk.RGB, strength: Double, clock: Double) {
        base.draw(in: &context, center: center, worldZ: worldZ, radius: radius, angles: angles,
                  style: OnboardingWireStrokes.style(fade: fade * 0.85, tint: tint, strength: strength * 0.72, clock: clock))
        let dy = press * 0.17 * norm
        var moved: [Int: Vec3] = [:]
        for (i, v) in cap.vertices.enumerated() { moved[i] = Vec3(x: v.x, y: v.y + dy, z: v.z) }
        cap.draw(in: &context, center: center, worldZ: worldZ, radius: radius, angles: angles,
                 style: OnboardingWireStrokes.style(fade: fade, tint: tint, strength: strength, clock: clock), moved: moved)
        OnboardingWireStrokes.draw(legend, in: &context, center: center, radius: radius, worldZ: worldZ, angles: angles,
                                   lift: dy, fade: fade, tint: tint, width: radius < 30 ? 1.1 : 1.3)
    }
}

enum OnboardingFinaleFigures {
    typealias Vec3 = OnboardingWireSolid.Vec3
    typealias Builder = OnboardingAccessFigures.Builder

    /// Try Drop's key, with the legend of the person's own Drop key (⌥, ⌘ or
    /// ⇧; a plain cap for any other key).
    static let dropKeys: [OnboardingKeycapLegend: OnboardingKeycapFigure] = [
        .none: OnboardingKeycapFigure(.none), .option: OnboardingKeycapFigure(.option),
        .command: OnboardingKeycapFigure(.command), .shift: OnboardingKeycapFigure(.shift),
    ]

    static func legend(for shortcut: HotkeyShortcut) -> OnboardingKeycapLegend {
        let text = shortcut.contents.map { content -> String in
            switch content {
            case .text(let value): return value
            case .symbol(let name, _): return name
            case .prefixedGlyph(let prefix, let glyph, _): return prefix + glyph
            }
        }.joined() + shortcut.title
        func has(_ marks: [String]) -> Bool { marks.contains { text.localizedCaseInsensitiveContains($0) } }
        if has(["⌘", "command"]) { return .command }
        if has(["⌥", "option"]) { return .option }
        if has(["⇧", "shift"]) { return .shift }
        return .none
    }
}

/// The thin line under Try Drop's lede: straight at rest, soft coloured waves
/// that follow the voice while Drop records, straight again when speech stops.
enum OnboardingVoiceLine {
    static func draw(in context: inout GraphicsContext, from x0: Double, to x1: Double, y: Double, amplitude: Double,
                     energy: Double, phase: Double, tone: OnboardingWireTone) {
        let base = OnboardingWireframeInk.wire
        func ink(_ rgb: OnboardingWireframeInk.RGB, _ alpha: Double) -> Color {
            Color(red: rgb.0, green: rgb.1, blue: rgb.2).opacity(alpha)
        }
        let ends = Path { path in
            path.addEllipse(in: CGRect(x: x0 - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
            path.addEllipse(in: CGRect(x: x1 - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
        }
        guard amplitude > 0.008 else {
            let mix = tone == .done || tone == .warn ? 0.55 : 0
            let rgb = (base.0 + (tone.tint.0 - base.0) * mix, base.1 + (tone.tint.1 - base.1) * mix,
                       base.2 + (tone.tint.2 - base.2) * mix)
            let alpha = mix > 0 ? 0.30 : 0.16
            context.stroke(Path { $0.move(to: CGPoint(x: x0, y: y)); $0.addLine(to: CGPoint(x: x1, y: y)) },
                           with: .color(ink(rgb, alpha)), lineWidth: 0.95)
            context.fill(ends, with: .color(ink(rgb, min(0.45, alpha * 1.65))))
            return
        }
        let n = 160, span = x1 - x0
        let a = 15.2 * min(1.15, amplitude) * energy
        let tau = 2 * Double.pi
        func wave(_ i: Int, _ f: (Double) -> Double) -> CGPoint {
            let u = Double(i) / Double(n)
            let taper = pow(sin(.pi * u), 1.75)
            return CGPoint(x: x0 + u * span, y: y + taper * a * f(u))
        }
        let strands: [(Double) -> Double] = [
            { u in 0.76 * sin(u * tau * 2.15 - phase * 3.8 + 0.35) + 0.24 * sin(u * tau * 4.2 - phase * 5.1 + 0.9) },
            { u in 0.64 * sin(u * tau * 2.95 - phase * 2.7 + 2.15) + 0.18 * cos(u * tau * 1.7 - phase * 3.9) },
            { u in 0.44 * sin(u * tau * 3.85 - phase * 4.9 + 3.85) + 0.14 * sin(u * tau * 5.3 - phase * 6.0) },
            { u in 0.30 * sin(u * tau * 1.45 - phase * 2.0 + 5.0) },
        ]
        let points = strands.map { f in (0...n).map { wave($0, f) } }
        func gradient(_ scale: Double) -> GraphicsContext.Shading {
            let edge = Color(red: base.0, green: base.1, blue: base.2).opacity(0.17)
            return .linearGradient(Gradient(stops: [
                .init(color: edge, location: 0),
                .init(color: Color(red: 0.651, green: 0.557, blue: 0.949).opacity(0.84 * scale), location: 0.15),
                .init(color: Color(red: 0.933, green: 0.494, blue: 0.729).opacity(0.98 * scale), location: 0.44),
                .init(color: Color(red: 0.965, green: 0.675, blue: 0.627).opacity(0.90 * scale), location: 0.69),
                .init(color: Color(red: 0.729, green: 0.573, blue: 0.918).opacity(0.78 * scale), location: 0.86),
                .init(color: edge, location: 1),
            ]), startPoint: CGPoint(x: x0, y: y), endPoint: CGPoint(x: x1, y: y))
        }
        // A faint ribbon between the first two strands, then the strands back to front.
        var ribbon = Path()
        ribbon.addLines(points[0])
        ribbon.addLines(points[1].reversed())
        ribbon.closeSubpath()
        context.fill(ribbon, with: gradient(0.11 * min(1, amplitude)))
        for (index, width, alpha) in [(3, 0.85, 0.30), (2, 0.95, 0.44), (1, 1.25, 0.66), (0, 1.75, 0.98)] {
            var path = Path()
            path.addLines(points[index])
            context.stroke(path, with: gradient(alpha * min(1, amplitude * 1.25)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        context.fill(ends, with: .color(ink(base, 0.28)))
    }
}
