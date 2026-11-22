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

// MARK: - Step 1: the stage's motion

/// The prototype's frame loop for step 1, in the stage's own coordinates.
/// Held by reference and stepped from the display-rate timeline; changing it
/// never re-runs SwiftUI layout.
final class OnboardingSourceMotion {
    enum Figure: Equatable { case laptop, key }

    struct Actor {
        var x: OnboardingSpring, y: OnboardingSpring, z = OnboardingSpring(0)
        var fade = OnboardingSpring(1), lit = OnboardingSpring(0)
        var kx = 0.0, ky = 0.0, impulse = 0.0
        var turn = OnboardingSpring(0), targetTurn = 0.0
        var apparent = 0.0
        init(x: Double, y: Double) { self.x = OnboardingSpring(x); self.y = OnboardingSpring(y) }
    }

    private(set) var laptop = Actor(x: 0, y: 0)
    private(set) var key = Actor(x: 0, y: 0)
    var hovered: Figure?
    var chosen: Figure?
    var offersLaptop = true
    private var pointer: CGPoint?
    private var lastPointer: CGPoint?
    private var pointerVelocity = CGVector.zero
    private(set) var clock = 1.35
    private var lastTime: TimeInterval?
    private var size: CGSize = .zero

    /// The prototype's 540 pt stage, scaled to this one.
    private var scale: Double { min(size.width / 540, 1) }
    private var midX: Double { size.width / 2 }
    private var homeY: Double { size.height * 0.40 }
    var radius: Double { min(64, size.height * 0.24) }

    private func home(_ figure: Figure) -> CGPoint {
        guard offersLaptop else { return CGPoint(x: midX, y: homeY) }
        return CGPoint(x: midX + (figure == .laptop ? -112 : 112) * scale, y: homeY)
    }

    private func target(_ figure: Figure) -> (x: Double, y: Double, z: Double, fade: Double, lit: Double) {
        let focus = hovered ?? chosen
        let h = home(figure)
        if focus == figure { return (midX, homeY + 2, 0.68, 1, 1) }
        if focus != nil, offersLaptop {
            return (midX + (figure == .laptop ? -106 : 106) * scale, homeY - 30, -1.22, 0.28, 0)
        }
        return (h.x, h.y, 0, 1, 0)
    }

    /// Lays the figures out at home the first time a size is known.
    func prepare(size: CGSize) {
        guard size != self.size, size.width > 0 else { return }
        let first = self.size == .zero
        self.size = size
        guard first else { return }
        for figure in [Figure.laptop, .key] {
            let t = target(figure)
            update(figure) { $0 = Actor(x: t.x, y: t.y); $0.z = OnboardingSpring(t.z); $0.fade = OnboardingSpring(t.fade); $0.lit = OnboardingSpring(t.lit) }
        }
    }

    private func update(_ figure: Figure, _ change: (inout Actor) -> Void) {
        if figure == .laptop { change(&laptop) } else { change(&key) }
    }

    func pointerMoved(to point: CGPoint?) {
        pointer = point
        guard let point else { hovered = nil; return }
        // The prototype's hit rules, with hysteresis once a figure is forward.
        let s = scale
        guard point.y > size.height * 0.08, point.y < size.height * 0.98, point.x > 22, point.x < size.width - 22 else {
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

    /// A click: a small press dip, and the key turns a quarter.
    func select(_ figure: Figure, still: Bool) {
        chosen = figure
        hovered = figure
        guard !still else { return }
        update(figure) {
            $0.z.velocity -= figure == .key ? 1.8 : 1.6
            if figure == .key { $0.targetTurn += .pi * 0.5 } else { $0.impulse = 1 }
        }
    }

    func step(time: TimeInterval, still: Bool) {
        let dt = min(0.04, lastTime.map { max(0, time - $0) } ?? 0.016)
        lastTime = time
        if !still { clock += dt }
        if dt > 0, let pointer {
            let previous = lastPointer ?? pointer
            let m = 1 - exp(-dt * 16)
            pointerVelocity.dx += ((pointer.x - previous.x) / dt - pointerVelocity.dx) * m
            pointerVelocity.dy += ((pointer.y - previous.y) / dt - pointerVelocity.dy) * m
        }
        lastPointer = pointer
        let decay = exp(-dt * 2.4)
        for figure in [Figure.laptop, .key] {
            let t = target(figure)
            update(figure) { a in
                // Pose: stiffness 135, damping 19.5; fade and light: 150, 22.
                a.x.step(to: t.x, stiffness: 135, damping: 19.5, dt: dt, still: still)
                a.y.step(to: t.y, stiffness: 135, damping: 19.5, dt: dt, still: still)
                a.z.step(to: t.z, stiffness: 135, damping: 19.5, dt: dt, still: still)
                a.fade.step(to: t.fade, stiffness: 150, damping: 22, dt: dt, still: still)
                a.lit.step(to: t.lit, stiffness: 150, damping: 22, dt: dt, still: still)
                a.turn.step(to: a.targetTurn, stiffness: 160, damping: 18, dt: dt, still: still)
                a.apparent = OnboardingWireSolid.apparentRadius(radius, worldZ: a.z.value)
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

    func laptopAngles(still: Bool) -> (Double, Double, Double) {
        let focus = hovered ?? chosen
        let tiltY = focus == .laptop && pointer != nil && !still ? Double((pointer!.x - laptop.x.value) / 160) * 0.14 : 0
        let tiltX = focus == .laptop && pointer != nil && !still ? Double((pointer!.y - laptop.y.value) / 160) * -0.09 : 0
        return (-0.34 + (still ? 0 : cos(clock * 0.48) * 0.065) + tiltX + laptop.kx - laptop.impulse * 0.08,
                0.40 + (still ? 0 : sin(clock * 0.62) * 0.14) + tiltY + laptop.ky, 0)
    }

    func laptopWave(still: Bool) -> [Int: Double] {
        let amplitude = still ? 0.045 : 0.032 + laptop.lit.value * 0.075 + laptop.impulse * 0.09
        return OnboardingWireCatalog.laptop.waveOffsets(amplitude: amplitude, clock: clock, speed: 2.2 + laptop.lit.value * 2)
    }

    func keyAngles(still: Bool) -> (Double, Double, Double) {
        let focus = hovered ?? chosen
        let tiltY = focus == .key && pointer != nil && !still ? Double((pointer!.x - key.x.value) / 160) * 0.15 : 0
        return (-0.26 + (still ? 0 : cos(clock * 0.72 + 0.6) * 0.22) + key.turn.value + key.kx,
                -0.44 + (still ? 0 : sin(clock * 0.56 + 1.4) * 0.15) + tiltY + key.ky,
                0.38 + (still ? 0 : sin(clock * 0.41) * 0.04))
    }
}

// MARK: - Step 1: how should Whytap hear you

/// On this Mac or API keys as two wire figures on a display-rate timeline.
/// Hover brings one forward; a click chooses it. Keyboard and VoiceOver use
/// the two buttons over the figures.
struct OnboardingSourceStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OnboardingSourceMotion()

    var body: some View {
        VStack(spacing: 0) {
            Text("How should Whytap hear you?")
                .font(OnboardingTheme.serifItalic(31))
                .foregroundColor(OnboardingTheme.ink)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            GeometryReader { proxy in
                stage(proxy.size)
            }
            if case .failed(let reason) = model.outcome(.source) {
                OnboardingStageStatus(tone: .warning, text: reason)
                    .padding(.horizontal, OnboardingTheme.compactHorizontalInset)
            }
        }
    }

    private var chosen: OnboardingSourceMotion.Figure? {
        switch model.progress.source {
        case .onThisMac: return .laptop
        case .yourKey: return .key
        case nil: return nil
        }
    }

    private func stage(_ size: CGSize) -> some View {
        let motion = self.motion
        let still = reduceMotion
        let offersLaptop = model.start.onDeviceSupported
        let chosen = self.chosen
        let laptopText = (title: "On this Mac", detail: laptopDetail)
        let keyText = (title: "API keys", detail: keyDetail)
        return ZStack {
            TimelineView(.animation(minimumInterval: still ? 1.0 / 30 : nil, paused: false)) { timeline in
                Canvas { context, canvasSize in
                    motion.offersLaptop = offersLaptop
                    motion.prepare(size: canvasSize)
                    if motion.chosen != chosen, !(motion.chosen != nil && chosen == nil) { motion.chosen = chosen }
                    motion.step(time: timeline.date.timeIntervalSinceReferenceDate, still: still)
                    let figures: [(OnboardingSourceMotion.Figure, OnboardingSourceMotion.Actor)] =
                        motion.laptop.z.value <= motion.key.z.value
                            ? [(.laptop, motion.laptop), (.key, motion.key)] : [(.key, motion.key), (.laptop, motion.laptop)]
                    for (figure, actor) in figures {
                        if figure == .laptop {
                            guard offersLaptop else { continue }
                            OnboardingWireCatalog.laptop.draw(
                                in: &context, center: CGPoint(x: actor.x.value, y: actor.y.value), worldZ: actor.z.value,
                                radius: motion.radius, angles: motion.laptopAngles(still: still),
                                style: OnboardingWireStyle(fade: actor.fade.value, lit: actor.lit.value),
                                waveY: motion.laptopWave(still: still))
                        } else {
                            OnboardingWireCatalog.key.draw(
                                in: &context, center: CGPoint(x: actor.x.value, y: actor.y.value), worldZ: actor.z.value,
                                radius: motion.radius, angles: motion.keyAngles(still: still),
                                style: OnboardingWireStyle(fade: actor.fade.value, lit: actor.lit.value))
                        }
                        let text = figure == .laptop ? laptopText : keyText
                        drawCaption(in: &context, actor: actor, title: text.title, detail: text.detail)
                    }
                }
            }
            .accessibilityHidden(true)

            // Buttons for keyboard and VoiceOver; the pointer goes to the stage.
            HStack(spacing: 0) {
                if offersLaptop { choiceButton(.laptop, label: "On this Mac. \(laptopDetail)") }
                choiceButton(.key, label: "API keys. \(keyDetail)")
            }
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): motion.pointerMoved(to: point)
            case .ended: motion.pointerMoved(to: nil)
            }
        }
        .onTapGesture { point in
            motion.pointerMoved(to: point)
            let figure = motion.hovered ?? (offersLaptop && point.x < size.width / 2 ? .laptop : .key)
            choose(figure)
        }
    }

    /// The title rides under its figure; a receded figure has no caption.
    private func drawCaption(in context: inout GraphicsContext, actor: OnboardingSourceMotion.Actor, title: String, detail: String) {
        let visible = actor.fade.value * min(1, max(0, (actor.z.value + 0.6) / 0.5))
        guard visible > 0.01 else { return }
        let scale = min(1.04, max(0.86, 1 + actor.z.value * 0.08))
        let top = actor.y.value + actor.apparent * 0.86 + 16
        var caption = context
        caption.opacity = visible
        caption.translateBy(x: actor.x.value, y: top)
        caption.scaleBy(x: scale, y: scale)
        caption.draw(Text(title).font(OnboardingTheme.sans(14.5, weight: .medium)).foregroundColor(OnboardingTheme.ink),
                     at: .zero, anchor: .top)
        let detailOpacity = min(1, max(0, (actor.lit.value - 0.18) / 0.72))
        guard detailOpacity > 0.01 else { return }
        caption.opacity = visible * detailOpacity
        caption.draw(Text(detail).font(OnboardingTheme.sans(12.5)).foregroundColor(OnboardingTheme.muted),
                     at: CGPoint(x: 0, y: 22 + (1 - detailOpacity) * 4), anchor: .top)
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

    private func choose(_ figure: OnboardingSourceMotion.Figure) {
        motion.select(figure, still: reduceMotion)
        figure == .laptop ? model.chooseOnThisMac() : model.chooseYourKey()
    }

    private func choiceButton(_ figure: OnboardingSourceMotion.Figure, label: String) -> some View {
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

/// The speech key: a wire key over a dark pill field. Pasting a whole key
/// checks it; Return or the arrow checks too. The key turns in its lock when
/// accepted and catches gently on a refusal; the middle of the key is masked.
struct OnboardingSpeechKeyStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var motion = OnboardingKeyMotion()

    private var providers: [OnboardingSpeechKeyProvider] { model.speechProviders.compactMap(OnboardingSpeechKeyProvider.of) }
    private var detected: (provider: OnboardingSpeechKeyProvider, prefix: Int)? {
        OnboardingSpeechKeyProvider.detect(draft, among: providers)
    }
    private var active: OnboardingSpeechKeyProvider {
        detected?.provider ?? OnboardingSpeechKeyProvider.of(model.speechProvider) ?? providers[0]
    }
    private var outcome: OnboardingStepOutcome { model.outcome(.speechKey) }
    private var checking: Bool { if case .working = outcome { return true } else { return false } }
    private var accepted: Bool { outcome.isDone }
    private var problem: OnboardingKeyProblem? {
        if case .failed = outcome { return model.keyProblems[.speechKey] ?? .other(outcome.failureText ?? "") } else { return nil }
    }
    private var saved: Bool { model.keySaved(active.kind) }

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect your speech key.")
                .font(OnboardingTheme.serifItalic(31))
                .foregroundColor(OnboardingTheme.ink)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            wireKey
                .frame(height: 92)
            field
                .padding(.horizontal, 44)
            feedback
                .frame(minHeight: 34)
                .padding(.horizontal, 36)
                .padding(.top, 8)
            Spacer(minLength: 4)
            footer
        }
        .onChange(of: outcome) { _, new in react(to: new) }
        .onAppear {
            focused = true
            motion.settle(phase: phase)
        }
    }

    private var phase: OnboardingKeyMotion.Phase {
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

    /// The key and the lock it turns in, stepped every display frame.
    private var wireKey: some View {
        let motion = self.motion
        let phase = self.phase
        let still = reduceMotion
        return TimelineView(.animation(minimumInterval: still ? 1.0 / 30 : nil, paused: false)) { timeline in
            Canvas { context, size in
                motion.phase = phase
                motion.step(time: timeline.date.timeIntervalSinceReferenceDate, still: still)
                motion.draw(in: &context, size: size, still: still)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var field: some View {
        HStack(spacing: 10) {
            ProviderBrandIcon(assetName: active.assetName, size: 15, color: OnboardingTheme.ink2)
                .frame(width: 18)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text(accepted ? "\(active.kind.displayName) key saved"
                         : saved ? "Saved \(active.kind.displayName) key · press Return to use it"
                         : "Paste your \(active.kind.displayName) key")
                        .font(OnboardingTheme.sans(13.5))
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
                        motion.targetTurn = 0
                        if detected == nil, let provider = OnboardingSpeechKeyProvider.detect(new, among: providers)?.provider {
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
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 50)
        .background(Capsule().fill(Color(red: 0.086, green: 0.086, blue: 0.098)))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        // A soft halo, not a neon band.
        .shadow(color: halo, radius: 14, x: 0, y: 0)
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 10)
        .animation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion), value: outcome)
        .animation(OnboardingMotion.resolve(OnboardingMotion.pressRelease, reduceMotion: reduceMotion), value: focused)
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
                    .font(.system(size: 12, weight: .semibold))
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
                Text("Press Return to check it with \(name).").foregroundColor(OnboardingTheme.muted)
            } else {
                Text("Paste a key. Whytap checks it with the provider in a second.").foregroundColor(OnboardingTheme.muted)
            }
        }
        .font(OnboardingTheme.sans(12.5))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(providers, id: \.kind) { provider in
                    let isActive = provider.kind == active.kind
                    Button {
                        draft = ""
                        model.speechProvider = provider.kind
                    } label: {
                        HStack(spacing: 6) {
                            ProviderBrandIcon(assetName: provider.assetName, size: 12,
                                              color: isActive ? OnboardingTheme.ink : OnboardingTheme.muted)
                            Text(provider.kind.displayName)
                                .font(OnboardingTheme.sans(11.5, weight: isActive ? .semibold : .regular))
                                .foregroundColor(isActive ? OnboardingTheme.ink : OnboardingTheme.muted)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(isActive ? Color.white.opacity(0.08) : .clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(checking)
                    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
                }
            }
            HStack(spacing: 14) {
                Link(destination: active.keysURL) {
                    Text(offerLine)
                        .font(OnboardingTheme.sans(11.5, weight: .medium))
                        .foregroundColor(OnboardingTheme.muted)
                }
                .buttonStyle(.plain)
                Button("Use your own server →") { model.openSettings(.apiAndModels, .dropFast) }
                    .buttonStyle(.plain)
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.faint)
                    .help("Add an OpenAI-compatible speech server in Settings → API & Models")
            }
        }
        .padding(.bottom, 2)
    }

    /// "Where do I get a key? ↗", with the provider's real free offer if any.
    private var offerLine: String {
        let name = active.kind.displayName
        if let hint = APIHintsView.hints.first(where: { $0.provider == name && $0.access == .noCard }) {
            return "Get your \(name) key · \(OnboardingJourneyView.shortOffer(hint)) ↗"
        }
        return "Where do I get a \(name) key? ↗"
    }

    private var border: Color {
        if accepted, draft.isEmpty { return OnboardingTheme.green.opacity(0.55) }
        if problem != nil { return OnboardingTheme.orange.opacity(0.50) }
        if checking { return OnboardingWireframeInk.roseColor.opacity(0.45) }
        return focused ? Color.white.opacity(0.26) : Color.white.opacity(0.10)
    }

    private var halo: Color {
        if checking { return OnboardingWireframeInk.roseColor.opacity(0.18) }
        if focused, problem == nil, !accepted { return OnboardingWireframeInk.roseColor.opacity(0.10) }
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
            if model.outcome(.speechKey).isDone { draft = "" }
        }
    }

    private func react(to outcome: OnboardingStepOutcome) {
        switch outcome {
        case .done:
            motion.targetTurn = .pi * 0.5
        case .failed:
            guard let problem else { return }
            switch problem {
            case .format: motion.nudgeBack()
            case .refused, .noSpeechAccess: motion.catchOnPin(0.32, still: reduceMotion)
            case .noCredit: motion.catchOnPin(0.48, still: reduceMotion)
            default: break
            }
        case .idle, .working:
            motion.targetTurn = 0
        }
    }
}

/// Step 2's frame loop, as in the prototype: the key slides toward the lock
/// as the key goes in (stiffness 140, damping 20), turns a quarter when the
/// provider accepts it (175, 19), and catches on a pin before easing back
/// when it is refused. Positions are the prototype's 540 pt stage scaled to
/// the key's radius.
final class OnboardingKeyMotion {
    enum Phase: Equatable { case empty, pasted, checking, accepted, refused, format, network }

    var phase: Phase = .empty
    var targetTurn = 0.0
    private var x = OnboardingSpring(-30)
    private var turn = OnboardingSpring(0)
    private var clock = 1.1
    private var lastTime: TimeInterval?
    private var catchGeneration = 0

    static let keyRadius = 40.0
    private static let scale = keyRadius / 54

    private var goalX: Double {
        switch phase {
        case .empty: return -30
        case .pasted: return -20
        case .checking, .accepted, .refused: return -4
        case .format: return -34
        case .network: return -26
        }
    }

    /// Opening on a step already done shows the end pose at once.
    func settle(phase: Phase) {
        self.phase = phase
        x = OnboardingSpring(goalX)
        if phase == .accepted { targetTurn = .pi * 0.5; turn = OnboardingSpring(targetTurn) }
    }

    func nudgeBack() { x.velocity -= 42 }

    func catchOnPin(_ angle: Double, still: Bool) {
        guard !still else { return }
        targetTurn = angle
        catchGeneration += 1
        let generation = catchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.catchGeneration == generation,
                  [.refused, .format, .network].contains(self.phase) else { return }
            self.targetTurn = 0
        }
    }

    func step(time: TimeInterval, still: Bool) {
        let dt = min(0.04, lastTime.map { max(0, time - $0) } ?? 0.016)
        lastTime = time
        if !still { clock += dt }
        x.step(to: goalX, stiffness: 140, damping: 20, dt: dt, still: still)
        turn.step(to: targetTurn, stiffness: 175, damping: 19, dt: dt, still: still)
    }

    func draw(in context: inout GraphicsContext, size: CGSize, still: Bool) {
        let s = Self.scale
        let mid = size.width / 2, y = size.height / 2
        let swayY = still ? 0 : sin(clock * 0.58) * 0.08
        let swayX = still ? 0 : cos(clock * 0.46) * 0.05
        var tint: OnboardingWireframeInk.RGB?
        var strength = 0.0
        switch phase {
        case .checking: tint = OnboardingWireframeInk.rose; strength = 0.65
        case .accepted: tint = OnboardingWireframeInk.green; strength = 0.78
        case .refused, .format, .network: tint = OnboardingWireframeInk.amber; strength = 0.68
        case .empty, .pasted: break
        }
        let lockX = mid + 36 * s
        OnboardingWireCatalog.lock.draw(
            in: &context, center: CGPoint(x: lockX, y: y), worldZ: 0, radius: 34 * s,
            angles: (-0.18 + swayX, -0.40 + swayY, 0.03),
            style: OnboardingWireStyle(fade: phase == .network ? 0.28 : 0.78, tint: tint, tintStrength: strength * 0.6))
        if phase == .network {
            // No answer: three quiet dots between the key and the lock.
            var dots = Path()
            for d in 0..<3 {
                let cx = mid + (12 + Double(d) * 6) * s
                dots.addEllipse(in: CGRect(x: cx - 1.1, y: y + 2 * s - 1.1, width: 2.2, height: 2.2))
            }
            context.fill(dots, with: .color(OnboardingWireframeInk.amberColor.opacity(0.45)))
        }
        let keyX = mid + x.value * s
        let waveX: Double? = phase == .checking && !still
            ? keyX + (-48 + (clock * 95).truncatingRemainder(dividingBy: 108)) * s : nil
        OnboardingWireCatalog.key.draw(
            in: &context, center: CGPoint(x: keyX, y: y), worldZ: 0, radius: Self.keyRadius,
            angles: (-0.20 + turn.value + swayX, -0.40 + swayY, 0.03),
            style: OnboardingWireStyle(fade: 1, tint: tint, tintStrength: strength, dotWaveX: waveX))
    }
}

extension OnboardingStepOutcome {
    var failureText: String? { if case .failed(let text) = self { return text } else { return nil } }
}
