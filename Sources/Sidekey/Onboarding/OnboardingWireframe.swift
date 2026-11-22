import AppKit
import SwiftUI

// The whytap.ai wireframe language of the first two steps (design pass of
// 2026-11-22, draft): a laptop, a key and a lock drawn as depth-sorted wire
// solids. Every pose is driven per display frame by damped springs that keep
// their velocity when the target changes, as in the HTML prototype: hover
// brings a figure forward, the other recedes along depth, dimmer and without
// its caption. Nothing is SwiftUI-animated here: Canvas would jump.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

/// The wire palette: silver wire with tints toward the viewer, on the
/// onboarding's dark ground.
enum OnboardingWireframeInk {
    typealias RGB = (Double, Double, Double)
    static let wire: RGB = (0.949, 0.945, 0.965)
    static let rose: RGB = (0.949, 0.463, 0.714)
    static let green: RGB = (0.435, 0.812, 0.592)
    static let amber: RGB = (0.910, 0.690, 0.408)
    static let roseColor = Color(red: rose.0, green: rose.1, blue: rose.2)
    static let amberColor = Color(red: amber.0, green: amber.1, blue: amber.2)
    static let veil = Color(red: 0.071, green: 0.071, blue: 0.086)
    /// The ground: lighter at the centre, the window's own colour at the edge.
    static let groundCenter = Color(red: 0.098, green: 0.098, blue: 0.118)
}

/// One damped spring (mass 1), integrated per frame like the prototype's
/// `stepSpring`: a changed goal keeps the current velocity, so a hover that
/// changes mid-flight bends the motion instead of restarting it.
struct OnboardingSpring {
    var value: Double
    var velocity = 0.0

    init(_ value: Double) { self.value = value }

    mutating func step(to goal: Double, stiffness: Double, damping: Double, dt: Double, still: Bool) {
        guard !still else { value = goal; velocity = 0; return }
        velocity = (velocity + (goal - value) * stiffness * dt) * exp(-damping * dt)
        value += velocity * dt
    }
}

/// How a solid is drawn this frame.
struct OnboardingWireStyle {
    var fade = 1.0
    /// Hover light: near wires warm toward rose, a soft veil sits behind.
    var lit = 0.0
    /// A state tint of the near wires (checking, accepted, refused).
    var tint: OnboardingWireframeInk.RGB?
    var tintStrength = 0.0
    /// The x of a light running along the dots while a key is checked.
    var dotWaveX: Double?
}

// MARK: - Wire solid

struct OnboardingWireSolid {
    struct Vec3 { var x: Double; var y: Double; var z: Double }
    /// A vertex of the laptop's screen line, moved up and down per frame.
    struct WavePoint { let index: Int; let f: Double; let baseY: Double }

    let vertices: [Vec3]
    let edges: [(Int, Int)]
    let dotIndices: [Int]
    let inkWeight: Double
    let wave: [WavePoint]
    private let rawScale: Double

    static let cameraDistance: Double = 4.0
    static let depthLevels = 6

    init(rawVertices: [Vec3], edges: [(Int, Int)], dotIndices: [Int], wave: [(index: Int, f: Double, baseY: Double)] = []) {
        let maxR = rawVertices.reduce(0.001) { max($0, sqrt($1.x * $1.x + $1.y * $1.y + $1.z * $1.z)) }
        let scaled = rawVertices.map { Vec3(x: $0.x / maxR, y: $0.y / maxR, z: $0.z / maxR) }
        var total = 0.0
        for (a, b) in edges {
            let dx = scaled[a].x - scaled[b].x, dy = scaled[a].y - scaled[b].y, dz = scaled[a].z - scaled[b].z
            total += sqrt(dx * dx + dy * dy + dz * dz)
        }
        vertices = scaled
        self.edges = edges
        self.dotIndices = dotIndices
        inkWeight = total > 0 ? min(1.0, max(0.56, sqrt(26.0 / total))) : 1.0
        rawScale = 1 / maxR
        self.wave = wave.map { WavePoint(index: $0.index, f: $0.f, baseY: $0.baseY / maxR) }
    }

    static func apparentRadius(_ radius: Double, worldZ: Double) -> Double {
        radius * (cameraDistance / max(1.2, cameraDistance - worldZ))
    }

    /// The prototype's screen pulse: a sine travelling along the line.
    func waveOffsets(amplitude: Double, clock: Double, speed: Double) -> [Int: Double] {
        var offsets: [Int: Double] = [:]
        for point in wave {
            let envelope = sin(point.f * .pi)
            let oscillation = sin(point.f * .pi * 2 * 2.5 - clock * speed)
            offsets[point.index] = point.baseY + envelope * oscillation * amplitude * rawScale
        }
        return offsets
    }

    /// Projects and draws back to front in depth buckets.
    func draw(in context: inout GraphicsContext, center: CGPoint, worldZ: Double, radius: Double,
              angles: (ax: Double, ay: Double, az: Double), style: OnboardingWireStyle, waveY: [Int: Double] = [:]) {
        guard style.fade > 0.01 else { return }
        let cx = cos(angles.ax), sx = sin(angles.ax)
        let cy = cos(angles.ay), sy = sin(angles.ay)
        let cz = cos(angles.az), sz = sin(angles.az)
        let m0 = cz * cy, m1 = cz * sy * sx - sz * cx, m2 = cz * sy * cx + sz * sx
        let m3 = sz * cy, m4 = sz * sy * sx + cz * cx, m5 = sz * sy * cx - cz * sx
        let m6 = -sy, m7 = cy * sx, m8 = cy * cx

        var points = [CGPoint](repeating: .zero, count: vertices.count)
        var depths = [Double](repeating: 0, count: vertices.count)
        var meanX = 0.0, meanY = 0.0
        for i in vertices.indices {
            let v = vertices[i]
            let y = waveY[i] ?? v.y
            let qx = m0 * v.x + m1 * y + m2 * v.z
            let qy = m3 * v.x + m4 * y + m5 * v.z
            let qz = m6 * v.x + m7 * y + m8 * v.z
            let k = Self.cameraDistance / max(1.2, Self.cameraDistance - (worldZ + qz * 0.55))
            points[i] = CGPoint(x: center.x + qx * k * radius, y: center.y + qy * k * radius)
            depths[i] = min(1, max(-1, qz * 0.78 + worldZ * 0.28))
            meanX += points[i].x
            meanY += points[i].y
        }
        meanX /= Double(max(1, vertices.count))
        meanY /= Double(max(1, vertices.count))
        let apparent = Self.apparentRadius(radius, worldZ: worldZ)
        let fine = min(1.14, max(0.58, apparent / 68))
        let lit = style.lit, fade = style.fade

        if lit > 0.03 {
            let veil = apparent * 1.15
            context.fill(Path(ellipseIn: CGRect(x: meanX - veil, y: meanY - veil, width: veil * 2, height: veil * 2)),
                         with: .radialGradient(Gradient(colors: [OnboardingWireframeInk.veil.opacity(0.54 * lit * fade),
                                                                 OnboardingWireframeInk.veil.opacity(0)]),
                                               center: CGPoint(x: meanX, y: meanY),
                                               startRadius: apparent * 0.15, endRadius: veil))
        }

        func bucket(_ depth: Double) -> Int {
            min(Self.depthLevels - 1, Int(min(1, max(0, (depth + 1) * 0.5)) * Double(Self.depthLevels)))
        }
        var edgePaths = [Path](repeating: Path(), count: Self.depthLevels)
        var dots = [[CGPoint]](repeating: [], count: Self.depthLevels)
        for (a, b) in edges {
            let level = bucket((depths[a] + depths[b]) * 0.5)
            edgePaths[level].move(to: points[a])
            edgePaths[level].addLine(to: points[b])
        }
        for index in dotIndices { dots[bucket(depths[index])].append(points[index]) }

        let base = OnboardingWireframeInk.wire
        for level in 0..<Self.depthLevels {
            let t = (Double(level) + 0.5) / Double(Self.depthLevels)
            let roseMix = lit * pow(t, 2.2) * 0.52
            let stateMix = style.tint == nil ? 0 : style.tintStrength * pow(t, 1.6)
            let target = style.tint ?? OnboardingWireframeInk.rose
            let mix = style.tint == nil ? roseMix : stateMix
            let color = Color(red: base.0 + (target.0 - base.0) * mix, green: base.1 + (target.1 - base.1) * mix,
                              blue: base.2 + (target.2 - base.2) * mix)
            if !edgePaths[level].isEmpty {
                let alpha = min(0.95, (0.11 + 0.50 * t + lit * 0.16 * t + stateMix * 0.22) * inkWeight * fade)
                context.stroke(edgePaths[level], with: .color(color.opacity(alpha)),
                               style: StrokeStyle(lineWidth: (0.56 + 0.95 * t + lit * 0.22 * t + stateMix * 0.2) * fine,
                                                  lineCap: .round, lineJoin: .round))
            }
            if !dots[level].isEmpty {
                let r = (0.82 + 1.35 * t + lit * 0.34 * t + stateMix * 0.3) * fine
                var path = Path()
                for p in dots[level] {
                    let boost = style.dotWaveX.map { exp(-pow((p.x - $0) / 26, 2)) * 1.15 } ?? 0
                    let rr = r + boost
                    path.addEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
                }
                let alpha = min(0.98, (0.30 + 0.54 * t + lit * 0.18 + stateMix * 0.2) * (0.65 + 0.35 * inkWeight) * fade)
                context.fill(path, with: .color(color.opacity(alpha)))
            }
        }
    }
}

enum OnboardingWireCatalog {
    static let laptop: OnboardingWireSolid = {
        var v: [OnboardingWireSolid.Vec3] = []
        var e: [(Int, Int)] = []
        var dots: [Int] = []
        func pt(_ x: Double, _ y: Double, _ z: Double, dot: Bool = false) -> Int {
            v.append(.init(x: x, y: y, z: z))
            if dot { dots.append(v.count - 1) }
            return v.count - 1
        }
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) { e.append(contentsOf: [(a, b), (b, c), (c, d), (d, a)]) }

        let hw = 0.78, yTop = 0.28, yBot = 0.355, zBack = -0.38, zFront = 0.58
        let tBL = pt(-hw, yTop, zBack, dot: true), tBR = pt(hw, yTop, zBack, dot: true)
        let tFR = pt(hw, yTop, zFront, dot: true), tFL = pt(-hw, yTop, zFront, dot: true)
        quad(tBL, tBR, tFR, tFL)
        let bBL = pt(-hw + 0.03, yBot, zBack + 0.03, dot: true), bBR = pt(hw - 0.03, yBot, zBack + 0.03, dot: true)
        let bFR = pt(hw - 0.03, yBot, zFront - 0.03, dot: true), bFL = pt(-hw + 0.03, yBot, zFront - 0.03, dot: true)
        quad(bBL, bBR, bFR, bFL)
        e.append(contentsOf: [(tBL, bBL), (tBR, bBR), (tFR, bFR), (tFL, bFL)])
        // The thumb notch on the front edge.
        let scL = pt(-0.14, yTop, zFront), scLD = pt(-0.11, yTop + 0.026, zFront)
        let scRD = pt(0.11, yTop + 0.026, zFront), scR = pt(0.14, yTop, zFront)
        e.append(contentsOf: [(scL, scLD), (scLD, scRD), (scRD, scR)])
        let kx0 = -0.65, kx1 = 0.65, kz0 = -0.27, kz1 = 0.15
        quad(pt(kx0, yTop, kz0), pt(kx1, yTop, kz0), pt(kx1, yTop, kz1), pt(kx0, yTop, kz1))
        for r in 1...3 {
            let zr = kz0 + (kz1 - kz0) * (Double(r) / 4)
            e.append((pt(kx0, yTop, zr), pt(kx1, yTop, zr)))
        }
        for c in 1...5 {
            let xc = kx0 + (kx1 - kx0) * (Double(c) / 6)
            e.append((pt(xc, yTop, kz0), pt(xc, yTop, kz1)))
        }
        quad(pt(-0.23, yTop, 0.23), pt(0.23, yTop, 0.23), pt(0.23, yTop, 0.50), pt(-0.23, yTop, 0.50))
        let lidH = 0.98, tilt = 0.25
        let dy = -cos(tilt) * lidH, dz = -sin(tilt) * lidH
        let lTL = pt(-hw, yTop + dy, zBack + dz, dot: true), lTR = pt(hw, yTop + dy, zBack + dz, dot: true)
        e.append(contentsOf: [(tBL, lTL), (tBR, lTR), (lTL, lTR)])
        let ny = -sin(tilt) * 0.042, nz = -cos(tilt) * 0.042
        let rBL = pt(-hw + 0.015, yTop + ny, zBack + nz), rBR = pt(hw - 0.015, yTop + ny, zBack + nz)
        let rTL = pt(-hw + 0.015, yTop + dy + ny, zBack + dz + nz, dot: true)
        let rTR = pt(hw - 0.015, yTop + dy + ny, zBack + dz + nz, dot: true)
        e.append(contentsOf: [(rBL, rTL), (rTL, rTR), (rTR, rBR), (lTL, rTL), (lTR, rTR), (tBL, rBL), (tBR, rBR)])
        func screen(_ x: Double, _ u: Double) -> Int { pt(x, yTop + dy * u, zBack + dz * u) }
        let sBL = screen(-hw + 0.07, 0.08), sBR = screen(hw - 0.07, 0.08)
        let sTL = screen(-hw + 0.07, 0.92), sTR = screen(hw - 0.07, 0.92)
        let n1 = screen(-0.11, 0.92), n2 = screen(-0.095, 0.865), n3 = screen(0.095, 0.865), n4 = screen(0.11, 0.92)
        e.append(contentsOf: [(sBL, sBR), (sBR, sTR), (sTL, sBL), (sTL, n1), (n1, n2), (n2, n3), (n3, n4), (n4, sTR)])
        // The pulse line across the screen.
        var wave: [(index: Int, f: Double, baseY: Double)] = []
        var previous = -1
        for s in 0...20 {
            let f = Double(s) / 20
            let index = pt(-0.44 + 0.88 * f, yTop + dy * 0.5, zBack + dz * 0.5 + 0.02, dot: s == 0 || s == 20)
            wave.append((index, f, yTop + dy * 0.5))
            if previous >= 0 { e.append((previous, index)) }
            previous = index
        }
        return OnboardingWireSolid(rawVertices: v, edges: e, dotIndices: dots, wave: wave)
    }()

    static let key: OnboardingWireSolid = {
        var v: [OnboardingWireSolid.Vec3] = []
        var e: [(Int, Int)] = []
        var dots: [Int] = []
        func pt(_ x: Double, _ y: Double, _ z: Double, dot: Bool = false) -> Int {
            v.append(.init(x: x, y: y, z: z))
            if dot { dots.append(v.count - 1) }
            return v.count - 1
        }
        let bowCx = -0.50, rOut = 0.43, rIn = 0.205, bowZ = 0.068, segs = 12
        var outF: [Int] = [], outB: [Int] = [], inF: [Int] = [], inB: [Int] = []
        for i in 0..<segs {
            let a = Double(i) / Double(segs) * .pi * 2
            let dot = i % 2 == 0
            outF.append(pt(bowCx + rOut * cos(a), rOut * sin(a), bowZ, dot: dot))
            outB.append(pt(bowCx + rOut * cos(a), rOut * sin(a), -bowZ, dot: dot))
            inF.append(pt(bowCx + rIn * cos(a), rIn * sin(a), bowZ * 0.82))
            inB.append(pt(bowCx + rIn * cos(a), rIn * sin(a), -bowZ * 0.82))
        }
        for i in 0..<segs {
            let n = (i + 1) % segs
            e.append(contentsOf: [(outF[i], outF[n]), (outB[i], outB[n]), (inF[i], inF[n]), (inB[i], inB[n])])
            if i % 2 == 0 { e.append(contentsOf: [(outF[i], outB[i]), (inF[i], inB[i])]) }
            if i % 3 == 0 { e.append(contentsOf: [(inF[i], outF[i]), (inB[i], outB[i])]) }
        }
        var shS: [Int] = [], shE: [Int] = []
        for i in 0..<6 {
            let a = Double(i) / 6 * .pi * 2
            shS.append(pt(-0.04, 0.056 * cos(a), 0.056 * sin(a)))
            shE.append(pt(0.86, 0.056 * cos(a), 0.056 * sin(a), dot: i % 2 == 0))
        }
        let tip = pt(0.97, 0, 0, dot: true)
        for i in 0..<6 {
            let n = (i + 1) % 6
            e.append(contentsOf: [(shS[i], shS[n]), (shE[i], shE[n]), (shS[i], shE[i])])
            if i % 2 == 0 { e.append((shE[i], tip)) }
        }
        let profile: [(Double, Double, Bool)] = [
            (0.31, 0.048, false), (0.31, 0.39, true), (0.42, 0.39, true), (0.42, 0.21, false),
            (0.52, 0.21, false), (0.52, 0.32, true), (0.62, 0.32, true), (0.62, 0.22, false),
            (0.71, 0.22, false), (0.71, 0.43, true), (0.82, 0.43, true), (0.82, 0.048, false),
        ]
        let bitF = profile.map { pt($0.0, $0.1, 0.042, dot: $0.2) }
        let bitB = profile.map { pt($0.0, $0.1, -0.042, dot: $0.2) }
        for i in profile.indices {
            if i + 1 < profile.count { e.append(contentsOf: [(bitF[i], bitF[i + 1]), (bitB[i], bitB[i + 1])]) }
            e.append((bitF[i], bitB[i]))
        }
        return OnboardingWireSolid(rawVertices: v, edges: e, dotIndices: dots)
    }()

    /// The lock cylinder the key turns in on step 2.
    static let lock: OnboardingWireSolid = {
        var v: [OnboardingWireSolid.Vec3] = []
        var e: [(Int, Int)] = []
        var dots: [Int] = []
        func pt(_ x: Double, _ y: Double, _ z: Double, dot: Bool = false) -> Int {
            v.append(.init(x: x, y: y, z: z))
            if dot { dots.append(v.count - 1) }
            return v.count - 1
        }
        let segs = 12, rOut = 0.72, rCore = 0.34, halfX = 0.32
        var fOut: [Int] = [], bOut: [Int] = [], fCore: [Int] = [], bCore: [Int] = []
        for i in 0..<segs {
            let a = Double(i) / Double(segs) * .pi * 2
            fOut.append(pt(-halfX, rOut * cos(a), rOut * sin(a), dot: i % 3 == 0))
            bOut.append(pt(halfX, rOut * cos(a), rOut * sin(a), dot: i % 3 == 0))
            fCore.append(pt(-halfX, rCore * cos(a), rCore * sin(a)))
            bCore.append(pt(halfX, rCore * cos(a), rCore * sin(a)))
        }
        for i in 0..<segs {
            let n = (i + 1) % segs
            e.append(contentsOf: [(fOut[i], fOut[n]), (bOut[i], bOut[n]), (fCore[i], fCore[n]), (bCore[i], bCore[n])])
            if i % 3 == 0 { e.append(contentsOf: [(fOut[i], bOut[i]), (fCore[i], fOut[i])]) }
        }
        for x in [-0.16, 0.0, 0.16] { e.append((pt(x, -rCore, 0, dot: true), pt(x, -rOut * 0.92, 0, dot: true))) }
        return OnboardingWireSolid(rawVertices: v, edges: e, dotIndices: dots)
    }()
}

// MARK: - Steps 1 and 2: one scene

/// The figures of steps 1 and 2 as one scene drawn above both steps, so the
/// key chosen on step 1 is the same key that flies to its lock on step 2 (and
/// back on Back), as in the prototype: never a fade between two drawings.
/// The steps report where their figure bands are and what they show; the
/// page's layer steps the springs every display frame and draws. Held by
/// reference: changing it never re-runs SwiftUI layout.
final class OnboardingWireScene {
    static let space = "onboarding.wire"

    enum Figure: Equatable { case laptop, key }
    enum Step: Equatable { case source, speechKey, beyond }
    enum KeyPhase: Equatable { case empty, pasted, checking, accepted, refused, format, network }

    struct Actor {
        var x: OnboardingSpring, y: OnboardingSpring, z = OnboardingSpring(0), r: OnboardingSpring
        var fade = OnboardingSpring(1), lit = OnboardingSpring(0)
        var kx = 0.0, ky = 0.0, impulse = 0.0
        var turn = OnboardingSpring(0), targetTurn = 0.0
        var apparent = 0.0
        init(x: Double, y: Double, r: Double) {
            self.x = OnboardingSpring(x); self.y = OnboardingSpring(y); self.r = OnboardingSpring(r)
        }
    }

    // Reported by the steps, in the page's coordinates.
    var pageWidth = 520.0
    var sourceTop = 0.0
    var sourceHeight = 0.0
    var keyBandY = 0.0
    var step: Step = .source
    var offersLaptop = true
    var hovered: Figure?
    var chosen: Figure?
    var keyPhase: KeyPhase = .empty
    /// Step 2's turn: a quarter when accepted, a catch on a pin when refused.
    var keyTargetTurn = 0.0
    var laptopCaption = ("", "")
    var keyCaption = ("", "")

    private(set) var laptop = Actor(x: 0, y: 0, r: 0)
    private(set) var key = Actor(x: 0, y: 0, r: 0)
    private var stage = OnboardingSpring(0)
    private var lockFade = OnboardingSpring(0)
    private var pointer: CGPoint?
    private var lastPointer: CGPoint?
    private var pointerVelocity = CGVector.zero
    private(set) var clock = 1.35
    private var lastTime: TimeInterval?
    private var placed = false
    private var catchGeneration = 0

    /// Step 2 draws the prototype's 540 pt key stage at the key's radius.
    static let keyRadius = 50.0
    private static let keyScale = keyRadius / 54

    // Step 1's layout: the prototype's 540 pt stage, scaled to the band.
    private var scale: Double { min(pageWidth / 540, 1) }
    private var midX: Double { pageWidth / 2 }
    private var homeY: Double { sourceTop + sourceHeight * 0.40 }
    var radius: Double { min(64, max(40, sourceHeight * 0.24)) }
    private var onKeyStep: Bool { step != .source }

    private var keyGoalX: Double {
        switch keyPhase {
        case .empty: return -30
        case .pasted: return -20
        case .checking, .accepted, .refused: return -4
        case .format: return -34
        case .network: return -26
        }
    }

    private func home(_ figure: Figure) -> CGPoint {
        guard offersLaptop else { return CGPoint(x: midX, y: homeY) }
        return CGPoint(x: midX + (figure == .laptop ? -112 : 112) * scale, y: homeY)
    }

    private func target(_ figure: Figure) -> (x: Double, y: Double, z: Double, r: Double, fade: Double, lit: Double) {
        if onKeyStep {
            // Step 2: the key over its lock; the laptop has receded away.
            if figure == .key { return (midX + keyGoalX * Self.keyScale, keyBandY, 0, Self.keyRadius, 1, 0) }
            return (midX - 106 * scale, homeY - 30, -1.5, radius * 0.8, 0, 0)
        }
        let focus = hovered ?? chosen
        let h = home(figure)
        if focus == figure { return (midX, homeY + 2, 0.68, radius, 1, 1) }
        if focus != nil, offersLaptop {
            return (midX + (figure == .laptop ? -106 : 106) * scale, homeY - 30, -1.22, radius, 0.28, 0)
        }
        return (h.x, h.y, 0, radius, 1, 0)
    }

    private var layoutKnown: Bool { onKeyStep ? keyBandY > 0 : sourceHeight > 0 }

    private func place() {
        stage = OnboardingSpring(onKeyStep ? 1 : 0)
        lockFade = OnboardingSpring(onKeyStep ? 0.78 : 0)
        for figure in [Figure.laptop, .key] {
            let t = target(figure)
            update(figure) {
                $0 = Actor(x: t.x, y: t.y, r: t.r)
                $0.z = OnboardingSpring(t.z); $0.fade = OnboardingSpring(t.fade); $0.lit = OnboardingSpring(t.lit)
            }
        }
        if onKeyStep { key.turn = OnboardingSpring(keyTargetTurn) }
    }

    private func update(_ figure: Figure, _ change: (inout Actor) -> Void) {
        if figure == .laptop { change(&laptop) } else { change(&key) }
    }

    // MARK: Input

    func pointerMoved(to point: CGPoint?) {
        guard step == .source else { return }
        pointer = point
        guard let point else { hovered = nil; return }
        // The prototype's hit rules, with hysteresis once a figure is forward.
        let s = scale
        guard point.y > sourceTop + sourceHeight * 0.08, point.y < sourceTop + sourceHeight * 0.98,
              point.x > 22, point.x < pageWidth - 22 else {
            hovered = nil
            return
        }
        guard offersLaptop else { hovered = .key; return }
        switch hovered {
        case .none:
            let laptopHome = home(.laptop), keyHome = home(.key)
            let dLaptop = hypot(point.x - laptopHome.x, (point.y - homeY - 24 * s) * 0.78)
            let dKey = hypot(point.x - keyHome.x, (point.y - homeY - 24 * s) * 0.78)
            if dLaptop < 118 * s, dLaptop < dKey { hovered = .laptop } else if dKey < 118 * s { hovered = .key }
        case .key:
            if point.x < midX - 72 * s { hovered = .laptop }
        case .laptop:
            if point.x > midX + 72 * s { hovered = .key }
        }
    }

    /// A click on step 1: a small press dip, and the key turns a quarter.
    func select(_ figure: Figure, still: Bool) {
        chosen = figure
        hovered = figure
        guard !still else { return }
        update(figure) {
            $0.z.velocity -= figure == .key ? 1.8 : 1.6
            if figure == .key { $0.targetTurn += .pi * 0.5 } else { $0.impulse = 1 }
        }
    }

    /// A key that is not a key slides back a little (step 2).
    func nudgeBack() { key.x.velocity -= 42 * Self.keyScale }

    /// The key catches on a pin, then eases back (step 2).
    func catchOnPin(_ angle: Double, still: Bool) {
        guard !still else { return }
        keyTargetTurn = angle
        catchGeneration += 1
        let generation = catchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.catchGeneration == generation,
                  [.refused, .format, .network].contains(self.keyPhase) else { return }
            self.keyTargetTurn = 0
        }
    }

    // MARK: Frame

    func advance(time: TimeInterval, still: Bool) {
        let dt = min(0.04, lastTime.map { max(0, time - $0) } ?? 0.016)
        lastTime = time
        guard layoutKnown else { return }
        if !placed { place(); placed = true }
        if !still { clock += dt }
        if step != .source { pointer = nil; lastPointer = nil; hovered = nil }
        if dt > 0, let pointer {
            let previous = lastPointer ?? pointer
            let m = 1 - exp(-dt * 16)
            pointerVelocity.dx += ((pointer.x - previous.x) / dt - pointerVelocity.dx) * m
            pointerVelocity.dy += ((pointer.y - previous.y) / dt - pointerVelocity.dy) * m
        }
        lastPointer = pointer
        stage.step(to: onKeyStep ? 1 : 0, stiffness: 135, damping: 19.5, dt: dt, still: still)
        lockFade.step(to: onKeyStep ? (keyPhase == .network ? 0.28 : 0.78) : 0, stiffness: 150, damping: 22, dt: dt, still: still)
        let decay = exp(-dt * 2.4)
        for figure in [Figure.laptop, .key] {
            let t = target(figure)
            let onLock = onKeyStep && figure == .key
            update(figure) { a in
                // Pose: 135/19.5 (the key's slide on step 2: 140/20); fade and light 150/22.
                a.x.step(to: t.x, stiffness: onLock ? 140 : 135, damping: onLock ? 20 : 19.5, dt: dt, still: still)
                a.y.step(to: t.y, stiffness: 135, damping: 19.5, dt: dt, still: still)
                a.z.step(to: t.z, stiffness: 135, damping: 19.5, dt: dt, still: still)
                a.r.step(to: t.r, stiffness: 135, damping: 19.5, dt: dt, still: still)
                a.fade.step(to: t.fade, stiffness: 150, damping: 22, dt: dt, still: still)
                a.lit.step(to: t.lit, stiffness: 150, damping: 22, dt: dt, still: still)
                if onLock {
                    a.turn.step(to: keyTargetTurn, stiffness: 175, damping: 19, dt: dt, still: still)
                } else {
                    a.turn.step(to: a.targetTurn, stiffness: 160, damping: 18, dt: dt, still: still)
                }
                a.apparent = OnboardingWireSolid.apparentRadius(a.r.value, worldZ: a.z.value)
                // A pointer passing near gives the figure a small spin.
                if let pointer, !still, a.fade.value > 0.35 {
                    let d = hypot(pointer.x - a.x.value, pointer.y - a.y.value)
                    let reach = a.apparent * 1.45
                    if d < reach {
                        let near = 1 - d / reach
                        a.kx = max(-0.5, min(0.5, a.kx - pointerVelocity.dy * near * dt * 0.0011))
                        a.ky = max(-0.5, min(0.5, a.ky + pointerVelocity.dx * near * dt * 0.0011))
                    }
                }
                a.kx *= decay
                a.ky *= decay
                a.impulse *= exp(-dt * 4.5)
            }
        }
    }

    private func laptopAngles(still: Bool) -> (Double, Double, Double) {
        let focus = hovered ?? chosen
        let tiltY = focus == .laptop && pointer != nil && !still ? Double((pointer!.x - laptop.x.value) / 160) * 0.14 : 0
        let tiltX = focus == .laptop && pointer != nil && !still ? Double((pointer!.y - laptop.y.value) / 160) * -0.09 : 0
        return (-0.34 + (still ? 0 : cos(clock * 0.48) * 0.065) + tiltX + laptop.kx - laptop.impulse * 0.08,
                0.40 + (still ? 0 : sin(clock * 0.62) * 0.14) + tiltY + laptop.ky, 0)
    }

    /// Step 1's pose blended into step 2's by the same spring that moves it.
    private func keyAngles(still: Bool) -> (Double, Double, Double) {
        let focus = hovered ?? chosen
        let tiltY = focus == .key && pointer != nil && !still ? Double((pointer!.x - key.x.value) / 160) * 0.15 : 0
        let first = (-0.26 + (still ? 0 : cos(clock * 0.72 + 0.6) * 0.22) + key.kx,
                     -0.44 + (still ? 0 : sin(clock * 0.56 + 1.4) * 0.15) + tiltY + key.ky,
                     0.38 + (still ? 0 : sin(clock * 0.41) * 0.04))
        let second = (-0.20 + (still ? 0 : cos(clock * 0.46) * 0.05),
                      -0.40 + (still ? 0 : sin(clock * 0.58) * 0.08), 0.03)
        let b = min(1.1, max(-0.1, stage.value))
        return (first.0 + (second.0 - first.0) * b + key.turn.value,
                first.1 + (second.1 - first.1) * b,
                first.2 + (second.2 - first.2) * b)
    }

    // MARK: Drawing

    func draw(in context: inout GraphicsContext, still: Bool) {
        guard placed else { return }
        let b = min(1, max(0, stage.value))
        let s = Self.keyScale
        let swayY = still ? 0 : sin(clock * 0.58) * 0.08
        let swayX = still ? 0 : cos(clock * 0.46) * 0.05
        var tint: OnboardingWireframeInk.RGB?
        var strength = 0.0
        if onKeyStep {
            switch keyPhase {
            case .checking: tint = OnboardingWireframeInk.rose; strength = 0.65
            case .accepted: tint = OnboardingWireframeInk.green; strength = 0.78
            case .refused, .format, .network: tint = OnboardingWireframeInk.amber; strength = 0.68
            case .empty, .pasted: break
            }
        }
        // The lock sits behind the key.
        if lockFade.value > 0.01 {
            OnboardingWireCatalog.lock.draw(
                in: &context, center: CGPoint(x: midX + 36 * s, y: keyBandY), worldZ: 0, radius: 34 * s,
                angles: (-0.18 + swayX, -0.40 + swayY, 0.03),
                style: OnboardingWireStyle(fade: lockFade.value, tint: tint, tintStrength: strength * 0.6 * b))
        }
        if onKeyStep, keyPhase == .network {
            // No answer: three quiet dots between the key and the lock.
            var dots = Path()
            for d in 0..<3 {
                let cx = midX + (12 + Double(d) * 6) * s
                dots.addEllipse(in: CGRect(x: cx - 1.1, y: keyBandY + 2 * s - 1.1, width: 2.2, height: 2.2))
            }
            context.fill(dots, with: .color(OnboardingWireframeInk.amberColor.opacity(0.45 * b)))
        }
        // Captions belong to step 1: gone in the first third of the flight.
        let captions = max(0, 1 - b * 3)
        let figures: [Figure] = laptop.z.value <= key.z.value ? [.laptop, .key] : [.key, .laptop]
        for figure in figures {
            if figure == .laptop {
                guard offersLaptop, laptop.fade.value > 0.01 else { continue }
                let amplitude = still ? 0.045 : 0.032 + laptop.lit.value * 0.075 + laptop.impulse * 0.09
                OnboardingWireCatalog.laptop.draw(
                    in: &context, center: CGPoint(x: laptop.x.value, y: laptop.y.value), worldZ: laptop.z.value,
                    radius: laptop.r.value, angles: laptopAngles(still: still),
                    style: OnboardingWireStyle(fade: laptop.fade.value, lit: laptop.lit.value),
                    waveY: OnboardingWireCatalog.laptop.waveOffsets(amplitude: amplitude, clock: clock,
                                                                   speed: 2.2 + laptop.lit.value * 2))
                drawCaption(in: &context, actor: laptop, text: laptopCaption, visible: captions)
            } else {
                let keyX = key.x.value
                let waveX: Double? = onKeyStep && keyPhase == .checking && !still
                    ? keyX + (-48 + (clock * 95).truncatingRemainder(dividingBy: 108)) * s : nil
                OnboardingWireCatalog.key.draw(
                    in: &context, center: CGPoint(x: keyX, y: key.y.value), worldZ: key.z.value,
                    radius: key.r.value, angles: keyAngles(still: still),
                    style: OnboardingWireStyle(fade: key.fade.value, lit: key.lit.value, tint: tint,
                                               tintStrength: strength * b, dotWaveX: waveX))
                drawCaption(in: &context, actor: key, text: keyCaption, visible: captions)
            }
        }
    }

    /// The title rides under its figure; a receded figure has no caption.
    private func drawCaption(in context: inout GraphicsContext, actor: Actor, text: (String, String), visible base: Double) {
        let visible = base * actor.fade.value * min(1, max(0, (actor.z.value + 0.6) / 0.5))
        guard visible > 0.01, !text.0.isEmpty else { return }
        let scale = min(1.04, max(0.86, 1 + actor.z.value * 0.08))
        let top = actor.y.value + actor.apparent * 0.86 + 16
        var caption = context
        caption.opacity = visible
        caption.translateBy(x: actor.x.value, y: top)
        caption.scaleBy(x: scale, y: scale)
        caption.draw(Text(text.0).font(OnboardingTheme.sans(14.5, weight: .medium)).foregroundColor(OnboardingTheme.ink),
                     at: .zero, anchor: .top)
        let detailOpacity = min(1, max(0, (actor.lit.value - 0.18) / 0.72))
        guard detailOpacity > 0.01 else { return }
        caption.opacity = visible * detailOpacity
        caption.draw(Text(text.1).font(OnboardingTheme.sans(12.5)).foregroundColor(OnboardingTheme.muted),
                     at: CGPoint(x: 0, y: 22 + (1 - detailOpacity) * 4), anchor: .top)
    }
}

/// The page's layer for the scene: one canvas over steps 1 and 2 at the
/// display's rate (30 fps under Reduce Motion, where every spring snaps).
struct OnboardingWireSceneLayer: View {
    let scene: OnboardingWireScene
    let step: OnboardingWireScene.Step
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scene = self.scene, step = self.step, still = reduceMotion
        TimelineView(.animation(minimumInterval: still ? 1.0 / 30 : nil, paused: false)) { timeline in
            Canvas { context, size in
                scene.pageWidth = size.width
                scene.step = step
                scene.advance(time: timeline.date.timeIntervalSinceReferenceDate, still: still)
                scene.draw(in: &context, still: still)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Step 1: how should Whytap hear you

/// On this Mac or API keys as two wire figures of the shared scene. Hover
/// brings one forward; a click chooses it and moves on. Keyboard and
/// VoiceOver use the two buttons over the figures.
struct OnboardingSourceStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    let scene: OnboardingWireScene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Text("How should Whytap hear you?")
                .font(OnboardingTheme.serifItalic(31))
                .foregroundColor(OnboardingTheme.ink)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            GeometryReader { proxy in
                band(proxy.frame(in: .named(OnboardingWireScene.space)))
            }
            if case .failed(let reason) = model.outcome(.source) {
                OnboardingStageStatus(tone: .warning, text: reason)
                    .padding(.horizontal, OnboardingTheme.compactHorizontalInset)
            }
        }
    }

    private var chosen: OnboardingWireScene.Figure? {
        switch model.progress.source {
        case .onThisMac: return .laptop
        case .yourKey: return .key
        case nil: return nil
        }
    }

    /// Tells the scene where the figures stand and what they say. The step's
    /// own sideways slide is not part of it: only the band's height counts.
    private func band(_ frame: CGRect) -> some View {
        let scene = self.scene
        let offersLaptop = model.start.onDeviceSupported
        scene.sourceTop = frame.minY
        scene.sourceHeight = frame.height
        scene.offersLaptop = offersLaptop
        if scene.chosen != chosen, !(scene.chosen != nil && chosen == nil) { scene.chosen = chosen }
        scene.laptopCaption = ("On this Mac", laptopDetail)
        scene.keyCaption = ("API keys", keyDetail)
        return ZStack {
            // Buttons for keyboard and VoiceOver; the pointer goes to the band.
            HStack(spacing: 0) {
                if offersLaptop { choiceButton(.laptop, label: "On this Mac. \(laptopDetail)") }
                choiceButton(.key, label: "API keys. \(keyDetail)")
            }
            .allowsHitTesting(false)
            // Return chooses the figure in front, like a click; no pill shows.
            Button("") {
                let figure = scene.hovered ?? chosen ?? (offersLaptop ? nil : .key)
                if let figure { choose(figure) }
            }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(OnboardingWireScene.space)) { phase in
            switch phase {
            case .active(let point): scene.pointerMoved(to: point)
            case .ended: scene.pointerMoved(to: nil)
            }
        }
        .onTapGesture(coordinateSpace: .named(OnboardingWireScene.space)) { point in
            scene.pointerMoved(to: point)
            let figure = scene.hovered ?? (offersLaptop && point.x < scene.pageWidth / 2 ? .laptop : .key)
            choose(figure)
        }
    }

    private var laptopDetail: String {
        switch onDevice.status {
        case .downloading(let fraction) where chosen == .laptop:
            return "Downloading the speech model · \(Int((fraction * 100).rounded()))%"
        case .ready where chosen == .laptop:
            return "Speech model ready · nothing leaves this Mac"
        default:
            return "Private speech on this Mac, even offline. 470 MB."
        }
    }

    private var keyDetail: String {
        let names = model.speechProviders.map(\.displayName)
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "") : names.joined()
        return "\(list), or your own server."
    }

    private func choose(_ figure: OnboardingWireScene.Figure) {
        scene.select(figure, still: reduceMotion)
        figure == .laptop ? model.chooseOnThisMac() : model.chooseYourKey()
    }

    private func choiceButton(_ figure: OnboardingWireScene.Figure, label: String) -> some View {
        Button { choose(figure) } label: { Color.clear }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(chosen == figure ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Step 2: the speech key


/// One provider of the speech key step, with where to get a key and pay.
struct OnboardingSpeechKeyProvider: Equatable {
    let kind: AIProviderKind
    let assetName: String
    let keysURL: URL
    let billingURL: URL
    /// Prefixes the provider's keys really start with; none for providers
    /// whose keys have no prefix (Soniox, Deepgram).
    let prefixes: [String]

    static func of(_ kind: AIProviderKind) -> OnboardingSpeechKeyProvider? {
        switch kind {
        case .soniox:
            return .init(kind: kind, assetName: "soniox", keysURL: URL(string: "https://console.soniox.com")!,
                         billingURL: URL(string: "https://console.soniox.com")!, prefixes: [])
        case .deepgram:
            return .init(kind: kind, assetName: "deepgram", keysURL: URL(string: "https://console.deepgram.com")!,
                         billingURL: URL(string: "https://console.deepgram.com")!, prefixes: [])
        case .elevenLabs:
            return .init(kind: kind, assetName: "elevenlabs", keysURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")!,
                         billingURL: URL(string: "https://elevenlabs.io/app/subscription")!, prefixes: ["sk_"])
        case .openAI:
            return .init(kind: kind, assetName: "openai", keysURL: URL(string: "https://platform.openai.com/api-keys")!,
                         billingURL: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!,
                         prefixes: ["sk-proj-", "sk-svcacct-", "sk-"])
        default:
            return nil
        }
    }

    /// The offered provider whose prefix a pasted key carries, longest first.
    /// "sk-ant-" and "sk-or-" are language model keys, never OpenAI speech.
    static func detect(_ key: String, among providers: [OnboardingSpeechKeyProvider]) -> (provider: OnboardingSpeechKeyProvider, prefix: Int)? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.hasPrefix("sk-ant-"), !key.hasPrefix("sk-or-") else { return nil }
        // Deepgram keys have no prefix but are 40 hexadecimal characters.
        if key.count == 40, key.allSatisfy(\.isHexDigit), let deepgram = providers.first(where: { $0.kind == .deepgram }) {
            return (deepgram, 4)
        }
        let candidates = providers.flatMap { provider in provider.prefixes.map { (provider, $0) } }
            .sorted { $0.1.count > $1.1.count }
        return candidates.first { key.hasPrefix($0.1) }.map { ($0.0, $0.1.count) }
    }
}

/// The start and the last four characters stay visible.
enum OnboardingKeyMask {
    static func masked(_ raw: String, prefix: Int?) -> String {
        let count = raw.count
        guard count > 0 else { return "" }
        if count <= 4 { return String(raw.prefix(1)) + String(repeating: "•", count: count - 1) }
        if count <= 9 { return String(raw.prefix(2)) + String(repeating: "•", count: count - 4) + String(raw.suffix(2)) }
        let head = min(prefix ?? 4, count - 5)
        let middle = min(12, max(6, count - head - 4))
        return String(raw.prefix(head)) + String(repeating: "•", count: middle) + String(raw.suffix(4))
    }
}

/// The speech key, laid out like the design pass: the shared wire key over
/// its lock, one pill field, a quiet line under it, four monochrome provider
/// marks and one quiet link, all on one centred axis. Pasting a whole key
/// checks it; Return or the arrow checks too. A mark shows its name on hover,
/// when picked or when the pasted key is recognised; nothing is preselected.
struct OnboardingSpeechKeyStage: View {
    /// The field's side inset; the footer's secondary action lines up with it.
    static let fieldInset: CGFloat = 44

    @ObservedObject var model: OnboardingJourneyModel
    let scene: OnboardingWireScene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var picked: AIProviderKind?
    @State private var hoveredLogo: AIProviderKind?

    private var providers: [OnboardingSpeechKeyProvider] { model.speechProviders.compactMap(OnboardingSpeechKeyProvider.of) }
    private var detected: (provider: OnboardingSpeechKeyProvider, prefix: Int)? {
        OnboardingSpeechKeyProvider.detect(draft, among: providers)
    }
    /// The provider the person or the key named; nil at rest.
    private var known: OnboardingSpeechKeyProvider? {
        detected?.provider ?? picked.flatMap(OnboardingSpeechKeyProvider.of)
    }
    /// The provider a check goes to.
    private var active: OnboardingSpeechKeyProvider {
        known ?? OnboardingSpeechKeyProvider.of(model.speechProvider) ?? providers[0]
    }
    private var outcome: OnboardingStepOutcome { model.outcome(.speechKey) }
    private var checking: Bool { if case .working = outcome { return true } else { return false } }
    private var accepted: Bool { outcome.isDone }
    private var problem: OnboardingKeyProblem? {
        if case .failed = outcome { return model.keyProblems[.speechKey] ?? .other(outcome.failureText ?? "") } else { return nil }
    }
    private var saved: Bool { model.keySaved(active.kind) }

    private var phase: OnboardingWireScene.KeyPhase {
        if checking { return .checking }
        if accepted, draft.isEmpty { return .accepted }
        if let problem {
            switch problem {
            case .format: return .format
            case .unreachable: return .network
            default: return .refused
            }
        }
        return draft.isEmpty ? .empty : .pasted
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Paste your speech key.")
                .font(OnboardingTheme.serifItalic(31))
                .foregroundColor(OnboardingTheme.ink)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            keyBand
                .frame(height: 108)
            field
                .padding(.horizontal, Self.fieldInset)
                .padding(.top, 4)
            feedback
                .frame(height: 36, alignment: .top)
                .padding(.horizontal, Self.fieldInset)
                .padding(.top, 10)
            Spacer(minLength: 4)
            logos
            Button { model.openSettings(.apiAndModels, .dropFast) } label: {
                Text("Use your own server →")
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
            }
            .buttonStyle(.plain)
            .help("Add an OpenAI-compatible speech server in Settings → API & Models")
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: outcome) { _, new in react(to: new) }
        .onChange(of: phase) { _, new in scene.keyPhase = new }
        .onAppear {
            focused = true
            scene.keyPhase = phase
            scene.keyTargetTurn = accepted ? .pi * 0.5 : 0
            if saved || accepted { picked = model.speechProvider }
        }
    }

    /// Where the shared key and its lock stand; the scene draws them.
    private var keyBand: some View {
        let scene = self.scene
        return GeometryReader { proxy in
            let y = proxy.frame(in: .named(OnboardingWireScene.space)).midY
            Color.clear
                .onAppear { scene.keyBandY = y }
                .onChange(of: y) { _, new in scene.keyBandY = new }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var field: some View {
        HStack(spacing: 10) {
            if let known {
                ProviderBrandIcon(assetName: known.assetName, size: 15, color: OnboardingTheme.ink2)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text(accepted ? "\(active.kind.displayName) key saved"
                         : saved ? "Saved \(active.kind.displayName) key · press Return to use it"
                         : "Paste your API key…")
                        .font(OnboardingTheme.sans(14))
                        .foregroundColor(OnboardingTheme.faint)
                        .lineLimit(1)
                } else {
                    Text(OnboardingKeyMask.masked(draft, prefix: detected?.prefix))
                        .font(OnboardingTheme.mono(13))
                        .foregroundColor(OnboardingTheme.ink)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.mono(13))
                    .foregroundColor(.clear)
                    .focused($focused)
                    .disabled(checking)
                    .onSubmit(submit)
                    .onChange(of: draft) { old, new in
                        scene.keyTargetTurn = 0
                        if let provider = OnboardingSpeechKeyProvider.detect(new, among: providers)?.provider {
                            model.speechProvider = provider.kind
                        }
                        // A whole key pasted at once is checked right away.
                        if new.count - old.count >= 16 { submit() }
                    }
                    .accessibilityLabel("\(active.kind.displayName) key")
            }
            .frame(maxWidth: .infinity)
            trailing
        }
        .padding(.leading, known == nil ? 20 : 16)
        .padding(.trailing, 8)
        .frame(height: 50)
        .background(Capsule().fill(Color(red: 0.086, green: 0.086, blue: 0.098)))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        // A soft halo, not a neon band.
        .shadow(color: halo, radius: 14, x: 0, y: 0)
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 10)
        .animation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion), value: outcome)
        .animation(OnboardingMotion.resolve(OnboardingMotion.pressRelease, reduceMotion: reduceMotion), value: focused)
        .animation(OnboardingMotion.resolve(OnboardingMotion.pressRelease, reduceMotion: reduceMotion), value: known?.kind)
    }

    @ViewBuilder private var trailing: some View {
        if let problem, problem.offersRetry {
            Button("Retry", action: submit)
                .buttonStyle(.plain)
                .font(OnboardingTheme.sans(12, weight: .semibold))
                .foregroundColor(OnboardingTheme.ink)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        } else {
            let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saved
            Button(action: submit) {
                Image(systemName: accepted ? "checkmark" : checking ? "ellipsis" : "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accepted ? OnboardingTheme.green : ready && !checking ? .black : OnboardingTheme.muted)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(accepted ? OnboardingTheme.green.opacity(0.16)
                                              : checking ? Color.clear : ready ? Color.white : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(!ready || checking || (accepted && draft.isEmpty))
            .accessibilityLabel(accepted ? "Key accepted" : checking ? "Checking" : "Check key")
        }
    }

    /// One quiet line under the field; empty at rest.
    @ViewBuilder private var feedback: some View {
        let name = active.kind.displayName
        Group {
            if checking {
                Text("Checking the key with \(name)…").foregroundColor(OnboardingTheme.muted)
            } else if accepted, draft.isEmpty {
                Text("\(name) key accepted · saved in your Keychain").foregroundColor(OnboardingTheme.green)
            } else if let problem {
                VStack(spacing: 3) {
                    Text(problem.message(provider: name)).foregroundColor(OnboardingTheme.orange)
                    switch problem {
                    case .refused, .noSpeechAccess:
                        Link("Open \(name) keys ↗", destination: active.keysURL).foregroundColor(OnboardingTheme.ink)
                    case .noCredit:
                        Link("Check billing ↗", destination: active.billingURL).foregroundColor(OnboardingTheme.ink)
                    default:
                        EmptyView()
                    }
                }
            } else if !draft.isEmpty {
                Text(detected != nil ? "\(name) key recognized. Press Return to check it."
                     : known != nil ? "Press Return to check it with \(name)."
                     : "Press Return to check it with \(name), or pick its provider below.")
                    .foregroundColor(OnboardingTheme.muted)
            } else if let known, !saved {
                Link(destination: known.keysURL) {
                    Text(offerLine(known)).foregroundColor(OnboardingTheme.muted)
                }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .font(OnboardingTheme.sans(12.5))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// "Need a Soniox key? Get one · $200 credit ↗", with the provider's real
    /// free offer if any.
    private func offerLine(_ provider: OnboardingSpeechKeyProvider) -> String {
        let name = provider.kind.displayName
        let article = name.first.map { "AEIOU".contains($0) } == true ? "an" : "a"
        if let hint = APIHintsView.hints.first(where: { $0.provider == name && $0.access == .noCard }) {
            return "Need \(article) \(name) key? Get one · \(OnboardingJourneyView.shortOffer(hint)) ↗"
        }
        return "Need \(article) \(name) key? Get one on \(name) ↗"
    }

    /// Monochrome marks of one optical height; the name opens on hover, when
    /// picked, or when the key is recognised.
    private var logos: some View {
        HStack(spacing: 10) {
            ForEach(providers, id: \.kind) { provider in
                let open = known?.kind == provider.kind || hoveredLogo == provider.kind
                let dimmed = detected != nil && !open
                Button {
                    picked = picked == provider.kind && draft.isEmpty ? nil : provider.kind
                    model.speechProvider = provider.kind
                    focused = true
                } label: {
                    HStack(spacing: 7) {
                        ProviderBrandIcon(assetName: provider.assetName, size: 19, color: OnboardingTheme.ink)
                            .frame(width: 20, height: 20)
                            .opacity(open ? 1 : dimmed ? 0.24 : provider.kind == .openAI ? 0.58 : 0.46)
                        if open {
                            Text(provider.kind.displayName)
                                .font(OnboardingTheme.sans(13, weight: .medium))
                                .foregroundColor(OnboardingTheme.ink)
                                .fixedSize()
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .padding(.leading, open ? 11 : 10)
                    .padding(.trailing, open ? 13 : 10)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.white.opacity(open ? 0.075 : 0)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(open ? 0.10 : 0), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(checking)
                .onHover { inside in
                    if inside { hoveredLogo = provider.kind } else if hoveredLogo == provider.kind { hoveredLogo = nil }
                }
                .accessibilityLabel(provider.kind.displayName)
                .accessibilityAddTraits(known?.kind == provider.kind ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: 36)
        .animation(OnboardingMotion.resolve(.spring(response: 0.28, dampingFraction: 0.86), reduceMotion: reduceMotion),
                   value: hoveredLogo)
        .animation(OnboardingMotion.resolve(.spring(response: 0.28, dampingFraction: 0.86), reduceMotion: reduceMotion),
                   value: known?.kind)
    }

    private var border: Color {
        if accepted, draft.isEmpty { return OnboardingTheme.green.opacity(0.55) }
        if problem != nil { return OnboardingTheme.orange.opacity(0.50) }
        if checking { return OnboardingWireframeInk.roseColor.opacity(0.45) }
        return focused ? Color.white.opacity(0.22) : Color.white.opacity(0.10)
    }

    private var halo: Color {
        if checking { return OnboardingWireframeInk.roseColor.opacity(0.18) }
        if focused, problem == nil, !accepted { return OnboardingWireframeInk.roseColor.opacity(0.08) }
        return .clear
    }

    private func submit() {
        guard !checking else { return }
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || saved else { return }
        let provider = active.kind
        model.speechProvider = provider
        Task {
            await model.useSpeechKey(key, provider: provider)
            if model.outcome(.speechKey).isDone {
                draft = ""
                picked = provider
            }
        }
    }

    private func react(to outcome: OnboardingStepOutcome) {
        switch outcome {
        case .done:
            picked = model.speechProvider
            scene.keyTargetTurn = .pi * 0.5
        case .failed:
            // The mark of the provider that answered stays open.
            picked = model.speechProvider
            guard let problem else { return }
            switch problem {
            case .format: scene.nudgeBack()
            case .refused, .noSpeechAccess: scene.catchOnPin(0.32, still: reduceMotion)
            case .noCredit: scene.catchOnPin(0.48, still: reduceMotion)
            default: break
            }
        case .idle, .working:
            scene.keyTargetTurn = 0
        }
    }
}

extension OnboardingStepOutcome {
    var failureText: String? { if case .failed(let text) = self { return text } else { return nil } }
}
