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

/// A fine static grain over the dark ground. Gradients this dark show bands
/// on 8-bit displays; a ±1-level noise dithers them away, as the web page's
/// own grain does.
struct OnboardingGrain: View {
    private static let tile: NSImage = {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in bytes.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) } ?? NSImage()
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .opacity(0.035)
            .blendMode(.overlay)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
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
    /// Light caught on the facets that face it (Kajiya-Kay on the wires): the
    /// design pass's "light on the edges" instead of a coloured spot.
    struct Specular {
        var rgb: OnboardingWireframeInk.RGB
        var strength: Double
        var light: (x: Double, y: Double, z: Double)
        var power = 6.0
        /// Dots catch the light too (step 2).
        var dots = false
        /// The x of a light running along the figure while a key is checked.
        var waveX: Double?
    }

    var fade = 1.0
    /// Hover: a dark veil behind and slightly stronger wires.
    var lit = 0.0
    var specular: Specular?
    /// Step 2's ink, as its prototype draws the key and padlock: line width
    /// from the figure's size, dots at full strength in every vertex.
    var keyStage = false
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

    /// Vertices already in the unit scale (the padlock's parts share one).
    init(normalized: [Vec3], edges: [(Int, Int)], dotIndices: [Int]) {
        var total = 0.0
        for (a, b) in edges {
            let dx = normalized[a].x - normalized[b].x, dy = normalized[a].y - normalized[b].y
            let dz = normalized[a].z - normalized[b].z
            total += sqrt(dx * dx + dy * dy + dz * dz)
        }
        vertices = normalized
        self.edges = edges
        self.dotIndices = dotIndices
        inkWeight = total > 0 ? min(1.0, max(0.58, sqrt(26.0 / total))) : 1.0
        rawScale = 1
        wave = []
    }

    static func apparentRadius(_ radius: Double, worldZ: Double) -> Double {
        radius * (cameraDistance / max(1.2, cameraDistance - worldZ))
    }

    /// The prototype's screen pulse: a sine travelling along the line.
    func waveOffsets(amplitude: Double, clock: Double, speed: Double) -> [Int: Vec3] {
        var moved: [Int: Vec3] = [:]
        for point in wave {
            let envelope = sin(point.f * .pi)
            let oscillation = sin(point.f * .pi * 2 * 2.5 - clock * speed)
            var v = vertices[point.index]
            v.y = point.baseY + envelope * oscillation * amplitude * rawScale
            moved[point.index] = v
        }
        return moved
    }

    /// Projects and draws back to front in depth buckets, then the facets
    /// that catch the light.
    func draw(in context: inout GraphicsContext, center: CGPoint, worldZ: Double, radius: Double,
              angles: (ax: Double, ay: Double, az: Double), style: OnboardingWireStyle, moved: [Int: Vec3] = [:]) {
        guard style.fade > 0.01 else { return }
        let m = Self.matrix(angles)
        let n = vertices.count
        var points = [CGPoint](repeating: .zero, count: n)
        var depths = [Double](repeating: 0, count: n)
        var q = [Vec3](repeating: Vec3(x: 0, y: 0, z: 0), count: n)
        var meanX = 0.0, meanY = 0.0
        for i in 0..<n {
            let v = moved[i] ?? vertices[i]
            let r = Vec3(x: m[0] * v.x + m[1] * v.y + m[2] * v.z,
                         y: m[3] * v.x + m[4] * v.y + m[5] * v.z,
                         z: m[6] * v.x + m[7] * v.y + m[8] * v.z)
            q[i] = r
            let k = Self.cameraDistance / max(1.2, Self.cameraDistance - (worldZ + r.z * 0.55))
            points[i] = CGPoint(x: center.x + r.x * k * radius, y: center.y + r.y * k * radius)
            depths[i] = min(1, max(-1, r.z * 0.78 + worldZ * 0.28))
            meanX += points[i].x
            meanY += points[i].y
        }
        meanX /= Double(max(1, n))
        meanY /= Double(max(1, n))
        let apparent = Self.apparentRadius(radius, worldZ: worldZ)
        let fine = style.keyStage ? min(1.06, max(0.60, radius / 58)) : min(1.14, max(0.58, apparent / 68))
        let lit = style.lit, fade = style.fade
        let two = style.keyStage

        // A neutral veil only: no coloured spot behind the figure.
        if lit > 0.03 {
            let veil = apparent * 1.08
            context.fill(Path(ellipseIn: CGRect(x: meanX - veil, y: meanY - veil, width: veil * 2, height: veil * 2)),
                         with: .radialGradient(Gradient(colors: [OnboardingWireframeInk.veil.opacity(0.52 * lit * fade),
                                                                 OnboardingWireframeInk.veil.opacity(0)]),
                                               center: CGPoint(x: meanX, y: meanY),
                                               startRadius: apparent * 0.12, endRadius: veil))
        }

        func bucket(_ depth: Double) -> Int {
            min(Self.depthLevels - 1, Int(min(1, max(0, (depth + 1) * 0.5)) * Double(Self.depthLevels)))
        }
        var edgePaths = [Path](repeating: Path(), count: Self.depthLevels)
        var dotPaths = [Path](repeating: Path(), count: Self.depthLevels)
        var specEdges = [Path](repeating: Path(), count: 3)
        var specDots = [[CGPoint]](repeating: [], count: 3)

        // The light and its half-vector toward the viewer.
        var hx = 0.0, hy = 0.0, hz = 0.0, lx = 0.0, ly = 0.0, lz = 0.0
        if let spec = style.specular {
            let lLen = max(0.0001, sqrt(spec.light.x * spec.light.x + spec.light.y * spec.light.y + spec.light.z * spec.light.z))
            lx = spec.light.x / lLen; ly = spec.light.y / lLen; lz = spec.light.z / lLen
            let hLen = sqrt(lx * lx + ly * ly + (lz + 1) * (lz + 1))
            hx = lx / hLen; hy = ly / hLen; hz = (lz + 1) / hLen
        }
        let specular = style.specular.flatMap { $0.strength > 0.02 ? $0 : nil }

        for (a, b) in edges {
            let level = bucket((depths[a] + depths[b]) * 0.5)
            edgePaths[level].move(to: points[a])
            edgePaths[level].addLine(to: points[b])
            guard let spec = specular else { continue }
            let tx = q[b].x - q[a].x, ty = q[b].y - q[a].y, tz = q[b].z - q[a].z
            let tLen = max(0.0001, sqrt(tx * tx + ty * ty + tz * tz))
            let dotTH = (tx * hx + ty * hy + tz * hz) / tLen
            let sinTH = sqrt(max(0, 1 - dotTH * dotTH))
            let nx = (q[a].x + q[b].x) * 0.5, ny = (q[a].y + q[b].y) * 0.5, nz = (q[a].z + q[b].z) * 0.5
            let nLen = max(0.0001, sqrt(nx * nx + ny * ny + nz * nz))
            let nDotL = (nx * lx + ny * ly + nz * lz) / nLen
            let front = min(1, max(0, (nz + 0.35) / 1.15))
            let midX = (points[a].x + points[b].x) * 0.5
            let wave = spec.waveX.map { exp(-pow((midX - $0) / 28, 2)) * 0.55 } ?? 0
            guard nDotL > -0.12, front > 0.10 else { continue }
            let value = spec.strength * front * max(0, nDotL * 0.72 + 0.28) * pow(sinTH, spec.power) + wave
            let tier = value > 0.52 ? 2 : value > 0.27 ? 1 : value > 0.12 ? 0 : -1
            if tier >= 0 {
                specEdges[tier].move(to: points[a])
                specEdges[tier].addLine(to: points[b])
            }
        }
        for index in dotIndices {
            let level = bucket(depths[index])
            let t = (Double(level) + 0.5) / Double(Self.depthLevels)
            let r = (0.82 + (two ? 1.28 : 1.30) * t + lit * 0.16 * t) * fine
            let p = points[index]
            dotPaths[level].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            guard let spec = specular, spec.dots else { continue }
            let v = q[index]
            let nLen = max(0.0001, sqrt(v.x * v.x + v.y * v.y + v.z * v.z))
            let nDotH = (v.x * hx + v.y * hy + v.z * hz) / nLen
            let front = min(1, max(0, (v.z + 0.25) / 1.1))
            let wave = spec.waveX.map { exp(-pow((p.x - $0) / 26, 2)) * 0.65 } ?? 0
            let value = spec.strength * front * pow(max(0, nDotH), 3) + wave
            let tier = value > 0.46 ? 2 : value > 0.22 ? 1 : value > 0.10 ? 0 : -1
            if tier >= 0 { specDots[tier].append(p) }
        }

        let base = OnboardingWireframeInk.wire
        let baseColor = Color(red: base.0, green: base.1, blue: base.2)
        for level in 0..<Self.depthLevels {
            let t = (Double(level) + 0.5) / Double(Self.depthLevels)
            if !edgePaths[level].isEmpty {
                let alpha = min(0.92, ((two ? 0.12 : 0.11) + 0.48 * t + lit * 0.08 * t) * inkWeight * fade)
                context.stroke(edgePaths[level], with: .color(baseColor.opacity(alpha)),
                               style: StrokeStyle(lineWidth: (0.56 + (two ? 0.90 : 0.92) * t + lit * 0.10 * t) * fine,
                                                  lineCap: .round, lineJoin: .round))
            }
            if !dotPaths[level].isEmpty {
                let alpha = two ? min(0.95, (0.30 + 0.54 * t) * fade)
                    : min(0.95, (0.28 + 0.52 * t + lit * 0.08) * (0.65 + 0.35 * inkWeight) * fade)
                context.fill(dotPaths[level], with: .color(baseColor.opacity(alpha)))
            }
        }
        guard let spec = specular else { return }
        for tier in 0..<3 {
            let st = (two ? [0.24, 0.48, 0.76] : [0.22, 0.46, 0.74])[tier]
            let mix = two ? 0.58 + 0.38 * st : 0.55 + 0.40 * st
            let color = Color(red: base.0 + (spec.rgb.0 - base.0) * mix, green: base.1 + (spec.rgb.1 - base.1) * mix,
                              blue: base.2 + (spec.rgb.2 - base.2) * mix)
            if !specEdges[tier].isEmpty {
                let alpha = two ? min(0.90, (0.20 + st * 0.52) * fade) : min(0.88, (0.22 + st * 0.50) * fade)
                context.stroke(specEdges[tier], with: .color(color.opacity(alpha)),
                               style: StrokeStyle(lineWidth: ((two ? 0.92 : 0.95) + st * (two ? 0.58 : 0.62)) * fine,
                                                  lineCap: .round, lineJoin: .round))
            }
            if !specDots[tier].isEmpty {
                let r = (1.30 + st * 0.72) * fine
                var path = Path()
                for p in specDots[tier] { path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)) }
                context.fill(path, with: .color(color.opacity(min(0.94, (0.32 + st * 0.52) * fade))))
            }
        }
    }

    /// The rotation the solids use: z · y · x Euler angles, row-major.
    static func matrix(_ angles: (ax: Double, ay: Double, az: Double)) -> [Double] {
        let cx = cos(angles.ax), sx = sin(angles.ax)
        let cy = cos(angles.ay), sy = sin(angles.ay)
        let cz = cos(angles.az), sz = sin(angles.az)
        return [cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx,
                sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx,
                -sy, cy * sx, cy * cx]
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

    /// The design pass's padlock (step 2): a chamfered body with the keyhole
    /// on the face toward the key, and a tubular shackle that lifts out and
    /// swings open around its heel.
    static let padlockBody: OnboardingWireSolid = {
        var v: [OnboardingWireSolid.Vec3] = []
        var e: [(Int, Int)] = []
        var dots: [Int] = []
        func pt(_ x: Double, _ y: Double, _ z: Double, dot: Bool = false) -> Int {
            v.append(OnboardingPadlock.normalize(x, y, z))
            if dot { dots.append(v.count - 1) }
            return v.count - 1
        }
        let xF = -0.26, xB = 0.26, yT = -0.04, yBot = 0.88, zW = 0.58, ch = 0.13
        let profile: [(Double, Double)] = [(yT, -zW + ch), (yT, zW - ch), (yT + ch, zW), (yBot - ch, zW),
                                           (yBot, zW - ch), (yBot, -zW + ch), (yBot - ch, -zW), (yT + ch, -zW)]
        let front = profile.map { pt(xF, $0.0, $0.1, dot: true) }
        let back = profile.map { pt(xB, $0.0, $0.1, dot: true) }
        for i in 0..<8 {
            let n = (i + 1) % 8
            e.append(contentsOf: [(front[i], front[n]), (back[i], back[n]), (front[i], back[i])])
        }
        // The collar seam.
        let seam = [pt(xF, 0.14, -zW), pt(xF, 0.14, zW), pt(xB, 0.14, zW), pt(xB, 0.14, -zW)]
        for i in 0..<4 { e.append((seam[i], seam[(i + 1) % 4])) }
        // The shackle's sockets on the top deck.
        for zc in [-0.34, 0.34] {
            let socket = (0..<6).map { i -> Int in
                let a = Double(i) / 6 * .pi * 2
                return pt(0.105 * cos(a), yT, zc + 0.105 * sin(a))
            }
            for i in 0..<6 { e.append((socket[i], socket[(i + 1) % 6])) }
        }
        // The keyhole's escutcheon and slot, facing the key.
        let ring = (0..<10).map { i -> Int in
            let a = Double(i) / 10 * .pi * 2
            return pt(xF - 0.008, 0.44 + 0.20 * sin(a), 0.20 * cos(a), dot: i % 5 == 0)
        }
        for i in 0..<10 { e.append((ring[i], ring[(i + 1) % 10])) }
        let slot = [pt(xF - 0.01, 0.35, -0.035, dot: true), pt(xF - 0.01, 0.35, 0.035, dot: true),
                    pt(xF - 0.01, 0.54, 0.026), pt(xF - 0.01, 0.54, -0.026)]
        for i in 0..<4 { e.append((slot[i], slot[(i + 1) % 4])) }
        return OnboardingWireSolid(normalized: v, edges: e, dotIndices: dots)
    }()
}

/// The padlock's shared unit scale and its moving shackle.
enum OnboardingPadlock {
    static let norm = 1 / 0.92

    static func normalize(_ x: Double, _ y: Double, _ z: Double) -> OnboardingWireSolid.Vec3 {
        .init(x: x * norm, y: (y - 0.06) * norm, z: z * norm)
    }

    /// The keyhole, in the padlock's unit space.
    static let keyhole = normalize(-0.26, 0.44, 0)

    private struct Spine { let y: Double; let z: Double; let ny: Double; let nz: Double; let dot: Bool }

    /// The shackle's tube before it moves: (x, y, z) rings along its spine.
    private static let rest: (points: [(Double, Double, Double)], edges: [(Int, Int)], dots: [Int]) = {
        let r = 0.34, tube = 0.082, archY = -0.36
        var spine: [Spine] = [.init(y: 0.42, z: r, ny: 0, nz: 1, dot: false), .init(y: -0.04, z: r, ny: 0, nz: 1, dot: true)]
        for s in 0...8 {
            let a = Double(s) / 8 * .pi
            spine.append(.init(y: archY - r * sin(a), z: r * cos(a), ny: -sin(a), nz: cos(a), dot: s % 2 == 0))
        }
        spine.append(.init(y: -0.06, z: -r, ny: 0, nz: -1, dot: true))
        spine.append(.init(y: 0.11, z: -r, ny: 0, nz: -1, dot: true))
        var points: [(Double, Double, Double)] = []
        var dots: [Int] = []
        var rings: [[Int]] = []
        for node in spine {
            var ring: [Int] = []
            for c in 0..<6 {
                let phi = Double(c) / 6 * .pi * 2
                let cr = sin(phi) * tube
                points.append((cos(phi) * tube, node.y + node.ny * cr, node.z + node.nz * cr))
                if node.dot && (c == 0 || c == 3) { dots.append(points.count - 1) }
                ring.append(points.count - 1)
            }
            rings.append(ring)
        }
        var edges: [(Int, Int)] = []
        for i in rings.indices {
            if i % 2 == 1 || i == rings.count - 1 { for c in 0..<6 { edges.append((rings[i][c], rings[i][(c + 1) % 6])) } }
            if i + 1 < rings.count { for c in [0, 1, 2, 4] { edges.append((rings[i][c], rings[i + 1][c])) } }
        }
        edges.append((rings[rings.count - 1][0], rings[rings.count - 1][3]))
        return (points, edges, dots)
    }()

    /// The shackle lifted by `lift` and swung by `swing` around its heel, with
    /// the prototype's slight outward cant while it lifts.
    static func shackle(lift: Double, swing: Double) -> OnboardingWireSolid {
        let pivotZ = 0.34, pivotY = -0.04
        let cant = lift / 0.42 * 0.16
        let cosCant = cos(cant), sinCant = sin(cant), cosSwing = cos(swing), sinSwing = sin(swing)
        let moved = rest.points.map { p -> OnboardingWireSolid.Vec3 in
            let dy0 = (p.1 - lift) - pivotY, dz0 = p.2 - pivotZ
            let y = pivotY + dy0 * cosCant - dz0 * sinCant
            let dz = dy0 * sinCant + dz0 * cosCant
            return normalize(p.0 * cosSwing + dz * sinSwing, y, -p.0 * sinSwing + dz * cosSwing + pivotZ)
        }
        return OnboardingWireSolid(normalized: moved, edges: rest.edges, dotIndices: rest.dots)
    }
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
        var x: OnboardingSpring, y: OnboardingSpring, z = OnboardingSpring(0)
        var fade = OnboardingSpring(1), lit = OnboardingSpring(0)
        var kx = 0.0, ky = 0.0, impulse = 0.0
        var turn = OnboardingSpring(0), targetTurn = 0.0
        var apparent = 0.0
        init(x: Double, y: Double) { self.x = OnboardingSpring(x); self.y = OnboardingSpring(y) }
    }

    // Reported by the steps, in the page's coordinates.
    var pageWidth = 520.0
    var pageHeight = 440.0
    var sourceTop = 0.0
    var sourceHeight = 0.0
    var keyBandY = 0.0
    var fieldY = 0.0
    var step: Step = .source
    var offersLaptop = true
    var hovered: Figure?
    var chosen: Figure?
    var keyPhase: KeyPhase = .empty {
        didSet { if keyPhase != oldValue { phaseChanged(from: oldValue) } }
    }
    var laptopCaption = ("", "")
    var keyCaption = ("", "")
    var reduceMotion = false

    private(set) var laptop = Actor(x: 0, y: 0)
    private(set) var key = Actor(x: 0, y: 0)
    /// 0: step 1's poses; 1: step 2's. The key flies on this spring.
    private var stage = OnboardingSpring(0)
    // Step 2's mechanics, the design pass's springs.
    private var insert = OnboardingSpring(0)
    private var lockTurn = OnboardingSpring(0)
    private var lockTargetTurn = 0.0
    private var lift = OnboardingSpring(0), targetLift = 0.0
    private var swing = OnboardingSpring(0), targetSwing = 0.0
    private var bodyY = OnboardingSpring(0)
    private var jolt = OnboardingSpring(0)
    private var pointer: CGPoint?
    private var lastPointer: CGPoint?
    private var pointerVelocity = CGVector.zero
    private(set) var clock = 1.35
    private var lastTime: TimeInterval?
    private var placed = false
    private var generation = 0

    // Step 1's layout: the prototype's 540 pt stage, scaled to the band.
    private var scale: Double { min(pageWidth / 540, 1) }
    private var midX: Double { pageWidth / 2 }
    private var homeY: Double { sourceTop + sourceHeight * 0.40 }
    var radius: Double { min(64, max(40, sourceHeight * 0.24)) }
    private var onKeyStep: Bool { step != .source }

    // Step 2's layout: the prototype's padlock and key, centred like its page.
    static let keyRadius = 48.0
    static let lockRadius = 38.0
    private var lockX: Double { midX + 48 }

    private func home(_ figure: Figure) -> CGPoint {
        guard offersLaptop else { return CGPoint(x: midX, y: homeY) }
        return CGPoint(x: midX + (figure == .laptop ? -112 : 112) * scale, y: homeY)
    }

    /// Step 1's pose of a figure (also held while step 2 shows: Back returns there).
    private func target(_ figure: Figure) -> (x: Double, y: Double, z: Double, fade: Double, lit: Double) {
        let focus = hovered ?? chosen
        let h = home(figure)
        if focus == figure { return (midX, homeY + 2, 0.68, 1, 1) }
        if focus != nil, offersLaptop {
            return (midX + (figure == .laptop ? -106 : 106) * scale, homeY - 30, -1.22, 0.28, 0)
        }
        return (h.x, h.y, 0, 1, 0)
    }

    private var insertGoal: Double {
        switch keyPhase {
        case .empty: return 0
        case .pasted: return 0.30
        case .checking, .accepted, .refused: return 1
        case .format: return -0.22
        case .network: return 0.12
        }
    }

    private var layoutKnown: Bool { onKeyStep ? keyBandY > 0 : sourceHeight > 0 }

    private func place() {
        stage = OnboardingSpring(onKeyStep ? 1 : 0)
        insert = OnboardingSpring(onKeyStep ? insertGoal : 0)
        if onKeyStep, keyPhase == .accepted {
            lockTargetTurn = .pi * 0.5; lockTurn = OnboardingSpring(lockTargetTurn)
            targetLift = 0.42; targetSwing = -0.54
            lift = OnboardingSpring(targetLift); swing = OnboardingSpring(targetSwing)
        }
        for figure in [Figure.laptop, .key] {
            let t = target(figure)
            update(figure) {
                $0 = Actor(x: t.x, y: t.y)
                $0.z = OnboardingSpring(t.z); $0.fade = OnboardingSpring(t.fade); $0.lit = OnboardingSpring(t.lit)
            }
        }
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

    /// The design pass's reactions on step 2: an accepted key turns, then the
    /// shackle pops up and swings open with a small kick of the body; a
    /// refused key goes in, tries to turn, the padlock shudders, and the key
    /// eases back; a malformed key stops short; any typing resets it.
    private func phaseChanged(from old: KeyPhase) {
        generation += 1
        let current = generation
        let still = reduceMotion
        switch keyPhase {
        case .accepted:
            lockTargetTurn = .pi * 0.5
            after(still ? 0 : 0.09, current) {
                $0.targetLift = 0.42
                $0.targetSwing = -0.54
                if !still { $0.bodyY.velocity += 34; $0.jolt.velocity += 0.55 }
            }
        case .refused:
            targetLift = 0; targetSwing = 0
            guard !still else { lockTargetTurn = 0; return }
            lockTargetTurn = refusedAngle
            jolt.velocity -= 0.72
            after(0.26, current) {
                $0.lockTargetTurn = 0
                $0.jolt.velocity += 0.35
            }
        case .format:
            targetLift = 0; targetSwing = 0; lockTargetTurn = 0
            if !still { insert.velocity -= 2.4 }
        case .empty, .pasted, .checking, .network:
            targetLift = 0; targetSwing = 0; lockTargetTurn = 0
        }
    }

    /// 0.36 rad for a refused key, 0.46 for no credit or no access.
    var refusedAngle = 0.36

    private func after(_ delay: TimeInterval, _ current: Int, _ change: @escaping (OnboardingWireScene) -> Void) {
        guard delay > 0 else { change(self); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == current else { return }
            change(self)
        }
    }

    // MARK: Frame

    func advance(time: TimeInterval, still: Bool) {
        let dt = min(0.04, lastTime.map { max(0, time - $0) } ?? 0.016)
        lastTime = time
        reduceMotion = still
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
        // Step 2: insertion 150/19, turn 185/18, shackle lift 230/14.5 and
        // swing 180/14, body recoil 210/16, shudder 260/15.
        insert.step(to: onKeyStep ? insertGoal : 0, stiffness: 150, damping: 19, dt: dt, still: still)
        lockTurn.step(to: lockTargetTurn, stiffness: 185, damping: 18, dt: dt, still: still)
        lift.step(to: targetLift, stiffness: 230, damping: 14.5, dt: dt, still: still)
        swing.step(to: targetSwing, stiffness: 180, damping: 14, dt: dt, still: still)
        bodyY.step(to: 0, stiffness: 210, damping: 16, dt: dt, still: still)
        jolt.step(to: 0, stiffness: 260, damping: 15, dt: dt, still: still)
        let decay = exp(-dt * 2.4)
        for figure in [Figure.laptop, .key] {
            let t = target(figure)
            update(figure) { a in
                // Pose: 135/19.5; fade and light: 150/22; the click's turn 160/18.
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

    private func laptopAngles(still: Bool) -> (Double, Double, Double) {
        let focus = hovered ?? chosen
        let tiltY = focus == .laptop && pointer != nil && !still ? Double((pointer!.x - laptop.x.value) / 160) * 0.14 : 0
        let tiltX = focus == .laptop && pointer != nil && !still ? Double((pointer!.y - laptop.y.value) / 160) * -0.09 : 0
        return (-0.34 + (still ? 0 : cos(clock * 0.48) * 0.065) + tiltX + laptop.kx - laptop.impulse * 0.08,
                0.40 + (still ? 0 : sin(clock * 0.62) * 0.14) + tiltY + laptop.ky, 0)
    }

    private func keyAnglesOnStepOne(still: Bool) -> (Double, Double, Double) {
        let focus = hovered ?? chosen
        let tiltY = focus == .key && pointer != nil && !still ? Double((pointer!.x - key.x.value) / 160) * 0.15 : 0
        return (-0.26 + (still ? 0 : cos(clock * 0.72 + 0.6) * 0.22) + key.kx + key.turn.value,
                -0.44 + (still ? 0 : sin(clock * 0.56 + 1.4) * 0.15) + tiltY + key.ky,
                0.38 + (still ? 0 : sin(clock * 0.41) * 0.04))
    }

    /// Step 2's shared camera: a 3/4 view that shows the key's profile and the
    /// padlock's face; the shudder rolls both.
    private func lockAngles(still: Bool) -> (Double, Double, Double) {
        (-0.20 + (still ? 0 : cos(clock * 0.44) * 0.06), -0.68 + (still ? 0 : sin(clock * 0.38) * 0.16),
         0.02 + jolt.value * 0.14)
    }

    /// The pair breathes in depth, slowly, like the key on step 1.
    private func lockBreath(still: Bool) -> Double { still ? 0 : sin(clock * 0.52) * 0.10 }

    // MARK: Drawing

    /// Step 1's light: a grazing key light catching the near facets in a calm
    /// rose-pearl.
    private func hoverLight(_ lit: Double) -> OnboardingWireStyle.Specular? {
        lit > 0.02 ? .init(rgb: (0.925, 0.596, 0.769), strength: lit, light: (0.52, -0.56, 0.64), power: 7) : nil
    }

    /// Step 2's light, from the field below: rose-pearl at rest and while
    /// checking, green when accepted, amber on a problem.
    private func islandLight(waveX: Double?) -> OnboardingWireStyle.Specular {
        var rgb: OnboardingWireframeInk.RGB = (0.925, 0.596, 0.769)
        var strength = 0.54
        switch keyPhase {
        case .checking: strength = 0.92
        case .accepted: rgb = OnboardingWireframeInk.green; strength = 0.88
        case .refused, .format, .network: rgb = OnboardingWireframeInk.amber; strength = 0.82
        case .empty, .pasted: break
        }
        let lx = -0.18 + (reduceMotion ? 0 : sin(clock * 0.62) * 0.16)
        return .init(rgb: rgb, strength: strength, light: (lx, 0.72, 0.66), power: 6, dots: true, waveX: waveX)
    }

    func draw(in context: inout GraphicsContext, still: Bool) {
        guard placed else { return }
        let b = min(1, max(0, stage.value))

        // The calm blush under the field (step 2).
        if b > 0.01, fieldY > 0 {
            let scale: Double = keyPhase == .checking ? 1.35
                : [.accepted, .refused, .format, .network].contains(keyPhase) ? 0.35 : 1
            var glow = context
            glow.opacity = b * scale
            glow.draw(Image(nsImage: OnboardingAmbientGlow.image), in: CGRect(x: midX - 270, y: fieldY - 222, width: 540, height: 420))
        }

        // Step 2's padlock and the keyway its keyhole looks along.
        let angles = lockAngles(still: still)
        let m = OnboardingWireSolid.matrix(angles)
        let hole = OnboardingPadlock.keyhole
        let hx = m[0] * hole.x + m[1] * hole.y + m[2] * hole.z
        let hy = m[3] * hole.x + m[4] * hole.y + m[5] * hole.z
        let hz = m[6] * hole.x + m[7] * hole.y + m[8] * hole.z
        let lockCenter = CGPoint(x: lockX, y: keyBandY + bodyY.value)
        let breath = lockBreath(still: still)
        let holeScale = OnboardingWireSolid.cameraDistance
            / max(1.2, OnboardingWireSolid.cameraDistance - (breath + hz * 0.55)) * Self.lockRadius
        let holeX = lockCenter.x + hx * holeScale, holeY = lockCenter.y + hy * holeScale
        let axisLength = max(0.0001, hypot(m[0], m[3]))
        let dirX = m[0] / axisLength, dirY = m[3] / axisLength
        let distance = 76 - insert.value * 51
        let seated = CGPoint(x: holeX - dirX * distance, y: holeY - dirY * distance)
        let waveX: Double? = onKeyStep && keyPhase == .checking && !still
            ? seated.x - 42 + (clock * 110).truncatingRemainder(dividingBy: 146) : nil
        let light = islandLight(waveX: waveX)

        if b > 0.01 {
            let fade = (keyPhase == .network ? 0.32 : 0.92) * b
            var shackleLight = light; shackleLight.strength *= 0.95
            var bodyLight = light; bodyLight.strength *= 0.80
            OnboardingPadlock.shackle(lift: lift.value, swing: swing.value).draw(
                in: &context, center: lockCenter, worldZ: breath, radius: Self.lockRadius, angles: angles,
                style: OnboardingWireStyle(fade: fade, specular: shackleLight, keyStage: true))
            OnboardingWireCatalog.padlockBody.draw(
                in: &context, center: lockCenter, worldZ: breath, radius: Self.lockRadius, angles: angles,
                style: OnboardingWireStyle(fade: fade, specular: bodyLight, keyStage: true))
            if keyPhase == .network {
                // Dots dimming toward the lock that does not answer.
                for d in 0..<3 {
                    let base = [0.48, 0.24, 0.09][d]
                    let pulse = still ? base : base * (0.55 + 0.45 * max(0, sin(clock * 2 - Double(d) * 1.1)))
                    let distance = 12 + Double(2 - d) * 8.5
                    let p = CGPoint(x: holeX - dirX * distance, y: holeY - dirY * distance)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1.45, y: p.y - 1.45, width: 2.9, height: 2.9)),
                                 with: .color(OnboardingWireframeInk.amberColor.opacity(pulse * b)))
                }
            }
        }

        // Step 1's figures; the key blends into step 2's pose along a slight arc.
        let captions = max(0, 1 - b * 3)
        let figures: [Figure] = laptop.z.value <= key.z.value ? [.laptop, .key] : [.key, .laptop]
        for figure in figures {
            if figure == .laptop {
                let fade = laptop.fade.value * (1 - b)
                guard offersLaptop, fade > 0.01 else { continue }
                let amplitude = still ? 0.045 : 0.032 + laptop.lit.value * 0.075 + laptop.impulse * 0.09
                OnboardingWireCatalog.laptop.draw(
                    in: &context, center: CGPoint(x: laptop.x.value, y: laptop.y.value), worldZ: laptop.z.value,
                    radius: radius, angles: laptopAngles(still: still),
                    style: OnboardingWireStyle(fade: fade, lit: laptop.lit.value, specular: hoverLight(laptop.lit.value)),
                    moved: OnboardingWireCatalog.laptop.waveOffsets(amplitude: amplitude, clock: clock,
                                                                   speed: 2.2 + laptop.lit.value * 2))
                drawCaption(in: &context, actor: laptop, text: laptopCaption, visible: captions)
            } else {
                let first = keyAnglesOnStepOne(still: still)
                let second = (angles.0 + lockTurn.value, angles.1, angles.2)
                let raw = min(1.1, max(-0.1, stage.value))
                let blended = (first.0 + (second.0 - first.0) * raw, first.1 + (second.1 - first.1) * raw,
                               first.2 + (second.2 - first.2) * raw)
                let arc = sin(.pi * b) * 14
                let center = CGPoint(x: key.x.value + (seated.x - key.x.value) * b,
                                     y: key.y.value + (seated.y - key.y.value) * b - arc)
                let z = key.z.value * (1 - b) + breath * b
                let lit = key.lit.value * (1 - b)
                var style = OnboardingWireStyle(fade: key.fade.value + (1 - key.fade.value) * b, lit: lit)
                if b > 0.5 { style.specular = light; style.keyStage = true } else { style.specular = hoverLight(lit) }
                OnboardingWireCatalog.key.draw(
                    in: &context, center: center, worldZ: z, radius: radius + (Self.keyRadius - radius) * b,
                    angles: blended, style: style)
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

/// The design pass's blush under the field: a smooth super-Gaussian in a calm
/// rose, dithered with interleaved gradient noise so 8-bit displays show no
/// bands. Built once, at the prototype's 540 × 420.
enum OnboardingAmbientGlow {
    static let image: NSImage = {
        let width = 540, height = 420
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let peak = 0.056, cx = Double(width) * 0.5, cy = 222.0, rx = 216.0, ry = 66.0
        func fract(_ v: Double) -> Double { v - floor(v) }
        for y in 0..<height {
            let dy = (Double(y) - cy) / ry
            for x in 0..<width {
                let dx = (Double(x) - cx) / rx
                let r2 = dx * dx + dy * dy
                let glow = r2 < 4.5 ? peak * exp(-r2 * 1.15) : 0
                let n1 = fract(52.9829189 * fract(0.06711056 * Double(x) + 0.00583715 * Double(y)))
                let n2 = fract(52.9829189 * fract(0.06711056 * Double(x + 29) + 0.00583715 * Double(y + 13)))
                let dither = (n1 - n2) * 1.35
                let i = (y * width + x) * 4
                guard glow > 0.001 else { continue }
                let alpha = max(0, min(255, (glow * 255 + dither).rounded()))
                // Premultiplied rose (206, 96, 150).
                bytes[i] = UInt8(206 * alpha / 255)
                bytes[i + 1] = UInt8(96 * alpha / 255)
                bytes[i + 2] = UInt8(150 * alpha / 255)
                bytes[i + 3] = UInt8(alpha)
            }
        }
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) } ?? NSImage()
    }()
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


/// One provider of a key step (speech or language model), with where to get
/// a key and pay.
struct OnboardingKeyProvider: Equatable {
    let kind: AIProviderKind
    let assetName: String
    let keysURL: URL
    let billingURL: URL

    static func of(_ kind: AIProviderKind) -> OnboardingKeyProvider? {
        func provider(_ asset: String, _ keys: String, _ billing: String) -> OnboardingKeyProvider {
            .init(kind: kind, assetName: asset, keysURL: URL(string: keys)!, billingURL: URL(string: billing)!)
        }
        switch kind {
        case .soniox: return provider("soniox", "https://console.soniox.com", "https://console.soniox.com")
        case .deepgram: return provider("deepgram", "https://console.deepgram.com", "https://console.deepgram.com")
        case .elevenLabs:
            return provider("elevenlabs", "https://elevenlabs.io/app/settings/api-keys", "https://elevenlabs.io/app/subscription")
        case .openAI:
            return provider("openai", "https://platform.openai.com/api-keys",
                            "https://platform.openai.com/settings/organization/billing/overview")
        case .anthropic:
            return provider("model-anthropic", "https://console.anthropic.com/settings/keys",
                            "https://console.anthropic.com/settings/billing")
        case .openRouter:
            return provider("openrouter", "https://openrouter.ai/settings/keys", "https://openrouter.ai/settings/credits")
        default:
            return nil
        }
    }

    /// The prefixes keys really start with, for every provider Whytap knows,
    /// longest first. Soniox keys have none; Deepgram's are 40 hexadecimal
    /// characters.
    static let prefixes: [(prefix: String, kind: AIProviderKind)] = [
        ("sk-svcacct-", .openAI), ("sk-proj-", .openAI), ("sk-ant-", .anthropic),
        ("sk-or-", .openRouter), ("sk_", .elevenLabs), ("sk-", .openAI),
    ]

    /// A real key is at least this long; shorter input is never recognised.
    static let minimumLength = 20

    /// The offered provider a key's own format names: a real prefix (the
    /// longest that matches, so "sk-ant-" is Anthropic, never OpenAI) or
    /// Deepgram's 40 hexadecimal characters. Any other string names nobody:
    /// the marks stay at rest and Return calls it a format problem.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    static func detect(_ key: String, among providers: [OnboardingKeyProvider]) -> OnboardingKeyProvider? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= minimumLength, OnboardingKeyMask.isKeyLike(key) else { return nil }
        if key.count == 40, key.allSatisfy(\.isHexDigit) {
            return providers.first { $0.kind == .deepgram }
        }
        guard let match = prefixes.first(where: { key.hasPrefix($0.prefix) }) else { return nil }
        return providers.first { $0.kind == match.kind }
    }
}

/// The key field is a secure field: any input (Latin, Cyrillic, digits,
/// symbols, the Russian layout's "№") is dots from its first character,
/// with no visible start or end. A wrong format is named only by the error
/// text on Return; the input itself never shows. One dot per character in
/// a monospaced font (Cyrillic and "№" have the same advance as a dot), so
/// the caret stays where the typed character is.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
enum OnboardingKeyMask {
    /// Characters a key is made of: Latin letters, digits, "-" and "_".
    /// Used to recognise a provider's format, never to decide what shows.
    static func isKeyLike(_ raw: String) -> Bool {
        !raw.isEmpty && raw.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// One dot per character; nil only for an empty field.
    static func masked(_ raw: String) -> String? {
        raw.isEmpty ? nil : String(repeating: "•", count: raw.count)
    }
}

/// Which key a key step asks for. Both steps share one layout, the wire key
/// over its padlock, the mask and the five problems.
enum OnboardingKeyStageKind: Equatable {
    case speech, languageModel

    var step: OnboardingStep {
        switch self {
        case .speech: return .speechKey
        case .languageModel: return .llmKey
        }
    }
    var title: String {
        switch self {
        case .speech: return "Paste your speech key."
        case .languageModel: return "Paste a language model key."
        }
    }
    init?(step: OnboardingStep) {
        switch step {
        case .speechKey: self = .speech
        case .llmKey: self = .languageModel
        default: return nil
        }
    }

    var serverHelp: String {
        switch self {
        case .speech: return "Add an OpenAI-compatible speech server (Ollama, LM Studio, vLLM)"
        case .languageModel: return "Add an OpenAI-compatible language model server (Ollama, LM Studio, vLLM)"
        }
    }
}

/// A key step, laid out like the design pass: the shared wire key over its
/// lock, one pill field, a quiet line under it, monochrome provider marks and
/// one quiet link, all on one centred axis. A pasted key whose format names
/// its provider is checked at once; Return or the arrow checks too. A mark
/// shows its name on hover, when picked or when the key is recognised;
/// nothing is preselected and nothing is guessed.
struct OnboardingKeyStage: View {
    /// The field's side inset; the footer's secondary action lines up with it.
    static let fieldInset: CGFloat = 44

    let kind: OnboardingKeyStageKind
    @ObservedObject var model: OnboardingJourneyModel
    let scene: OnboardingWireScene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var draft = ""
    /// A mark the person clicked: the one choice that names a provider
    /// without the key's own format.
    @State private var picked: AIProviderKind?
    @State private var hoveredLogo: AIProviderKind?
    @State private var hoveredServer = false
    /// The key field and the own-server fields share one capsule.
    @Namespace private var morph
    @State private var serverGrown = false

    private var step: OnboardingStep { kind.step }
    private var providers: [OnboardingKeyProvider] {
        switch kind {
        case .speech: return model.speechProviders.compactMap(OnboardingKeyProvider.of)
        case .languageModel: return OnboardingJourneyModel.llmProviders.compactMap(OnboardingKeyProvider.of)
        }
    }
    private var detected: OnboardingKeyProvider? { OnboardingKeyProvider.detect(draft, among: providers) }
    /// The provider the key's format or the person named; nil otherwise.
    private var known: OnboardingKeyProvider? { detected ?? picked.flatMap(OnboardingKeyProvider.of) }
    /// The step's provider in the model: whose key is saved or was answered.
    private var current: AIProviderKind {
        switch kind {
        case .speech: return model.speechProvider
        case .languageModel: return model.llmProvider
        }
    }
    private func setCurrent(_ provider: AIProviderKind) {
        if kind == .speech { model.speechProvider = provider } else { model.llmProvider = provider }
    }
    /// The provider that answered (a saved or accepted key with the field
    /// empty, or a refusal); never for a key that named nobody.
    private var settled: OnboardingKeyProvider? {
        let answered = problem.map { $0 != .unrecognized } ?? false
        return (draft.isEmpty && (accepted || saved)) || answered ? OnboardingKeyProvider.of(current) : nil
    }
    /// The mark in the field and the name in the lines under it.
    private var shown: OnboardingKeyProvider? { known ?? settled }
    private var outcome: OnboardingStepOutcome { model.outcome(step) }
    private var checking: Bool { if case .working = outcome { return true } else { return false } }
    /// A new key in the field is a new attempt, never the earlier answer.
    private var accepted: Bool { outcome.isDone && draft.isEmpty }
    private var problem: OnboardingKeyProblem? {
        if case .failed = outcome { return model.keyProblems[step] ?? .other(outcome.failureText ?? "") } else { return nil }
    }
    private var saved: Bool { model.keySaved(current) }

    private var phase: OnboardingWireScene.KeyPhase {
        if checking { return .checking }
        if accepted { return .accepted }
        if let problem {
            switch problem {
            case .format, .unrecognized: return .format
            case .unreachable: return .network
            default: return .refused
            }
        }
        return draft.isEmpty ? .empty : .pasted
    }

    /// "Self-hosted" turned the key field into the server's fields.
    private var server: Bool { model.showsServerForm(kind) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(server ? "Your own server." : kind.title)
                    .id(server)
                    .transition(.opacity)
            }
            .font(OnboardingTheme.serifItalic(31))
            .foregroundColor(OnboardingTheme.ink)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
            keyBand
                .frame(height: server ? 86 : 100)
            if server {
                OnboardingServerFields(kind: kind, model: model, scene: scene, morph: morph, grown: $serverGrown)
                    .padding(.horizontal, Self.fieldInset)
                    .padding(.top, 1)
                    .onAppear {
                        withAnimation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion)) {
                            serverGrown = true
                        }
                    }
                // Escape folds the fields back into the key field.
                Button("", action: backToKeys)
                    .keyboardShortcut(.cancelAction)
                    .disabled(checking || outcome.isDone)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityLabel("Back to keys")
            } else {
                field
                    .padding(.horizontal, Self.fieldInset)
                    .padding(.top, 4)
                feedback
                    .frame(height: 44, alignment: .top)
                    .padding(.horizontal, Self.fieldInset)
                    .padding(.top, 9)
            }
            // The same row in both, right under the fields: a provider mark
            // returns to its key, Self-hosted turns the key field into the
            // server's fields.
            logos
                .padding(.top, server ? 2 : 10)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
        .animation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion, allowFade: true),
                   value: server)
        .onChange(of: outcome) { _, new in react(to: new) }
        .onChange(of: phase) { _, new in
            scene.refusedAngle = problem == .noCredit || problem == .noSpeechAccess ? 0.46 : 0.36
            scene.keyPhase = new
        }
        .onAppear {
            focused = true
            scene.keyPhase = phase
        }
    }

    /// The lower fields fold into the first, then it becomes the key field.
    private func backToKeys() {
        withAnimation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion)) {
            serverGrown = false
        }
        let kind = self.kind
        let model = self.model
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.18)) {
            model.closeServerForm(kind)
            focused = true
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
            if let shown {
                ProviderBrandIcon(assetName: shown.assetName, size: 14, color: OnboardingTheme.ink)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            ZStack(alignment: .leading) {
                let masked = OnboardingKeyMask.masked(draft)
                if draft.isEmpty {
                    Text(accepted ? "\(current.displayName) key saved"
                         : saved ? "Saved \(current.displayName) key · press Return to use it"
                         : "Paste your API key…")
                        .font(OnboardingTheme.sans(14))
                        .foregroundColor(OnboardingTheme.faint)
                        .lineLimit(1)
                } else if let masked {
                    // Same length and font as the typed text: the caret and the
                    // field's scrolling stay where they are.
                    GeometryReader { proxy in
                        let overflows = Self.monoWidth(masked) > proxy.size.width
                        Text(masked)
                            .font(OnboardingTheme.mono(13))
                            .foregroundColor(OnboardingTheme.ink)
                            .fixedSize()
                            .frame(width: proxy.size.width, height: proxy.size.height,
                                   alignment: overflows ? .trailing : .leading)
                    }
                    .clipped()
                    .accessibilityHidden(true)
                }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.mono(13))
                    .foregroundColor(masked == nil ? OnboardingTheme.ink : .clear)
                    .focused($focused)
                    .disabled(checking)
                    .onSubmit(submit)
                    .onChange(of: draft) { old, new in
                        model.keyEdited(on: step)
                        guard let provider = OnboardingKeyProvider.detect(new, among: providers) else { return }
                        setCurrent(provider.kind)
                        // A whole key pasted at once is checked right away,
                        // only when its own format names the provider.
                        if new.count - old.count >= 16 { submit() }
                    }
                    .accessibilityLabel(shown.map { "\($0.kind.displayName) key" } ?? "API key")
            }
            .frame(maxWidth: .infinity)
            trailing
        }
        .padding(.leading, shown == nil ? 20 : 12)
        .padding(.trailing, 8)
        .frame(height: 50)
        .background(Capsule().fill(Color(red: 0.086, green: 0.086, blue: 0.098))
            .matchedGeometryEffect(id: "field", in: morph))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        // A soft halo, not a neon band.
        .shadow(color: halo, radius: 14, x: 0, y: 0)
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 10)
        .background(GeometryReader { proxy in
            let y = proxy.frame(in: .named(OnboardingWireScene.space)).midY
            Color.clear
                .onAppear { scene.fieldY = y }
                .onChange(of: y) { _, new in scene.fieldY = new }
        })
        .animation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion), value: outcome)
        .animation(OnboardingMotion.resolve(OnboardingMotion.pressRelease, reduceMotion: reduceMotion), value: focused)
        .animation(OnboardingMotion.resolve(OnboardingMotion.pressRelease, reduceMotion: reduceMotion), value: shown?.kind)
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
            .disabled(!ready || checking || accepted)
            .accessibilityLabel(accepted ? "Key accepted" : checking ? "Checking" : "Check key")
        }
    }

    /// One quiet line under the field; empty at rest.
    @ViewBuilder private var feedback: some View {
        let name = (shown?.kind ?? current).displayName
        Group {
            if checking {
                Text("Checking the key with \(name)…").foregroundColor(OnboardingTheme.muted)
            } else if accepted, choices.count > 1 {
                // The key worked with the recommended model set; the step
                // waits for a pick in "Choose model" or Next.
                VStack(spacing: 5) {
                    Text("\(name) key accepted · saved in your Keychain").foregroundColor(OnboardingTheme.green)
                    OnboardingModelMenu(choices: choices, selected: model.currentModel(step),
                                        recommended: model.recommendedModel(step),
                                        picked: model.pickedModels.contains(step),
                                        busy: model.choosingModel == step,
                                        opened: { model.modelMenu(open: $0) }) { id in
                        Task { await model.chooseModel(id, on: step) }
                    }
                }
            } else if accepted {
                Text(acceptedLine(name)).foregroundColor(OnboardingTheme.green)
            } else if let problem {
                VStack(spacing: 3) {
                    Text(problem.message(provider: name)).foregroundColor(OnboardingTheme.orange)
                    if let provider = shown {
                        switch problem {
                        case .refused, .noSpeechAccess:
                            Link("Open \(name) keys ↗", destination: provider.keysURL).foregroundColor(OnboardingTheme.ink)
                        case .noCredit:
                            Link("Check billing ↗", destination: provider.billingURL).foregroundColor(OnboardingTheme.ink)
                        default:
                            EmptyView()
                        }
                    }
                }
            } else if !draft.isEmpty {
                Text(detected != nil ? "\(name) key recognized\(modelSuffix(name)). Press Return to check it."
                     : known != nil ? "Press Return to check it with \(name)."
                     : "Press Return to check it, or pick its provider below.")
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

    private var choices: [OnboardingModelChoice] { model.modelChoices(step) }

    private func acceptedLine(_ name: String) -> String {
        if case .done(let what) = outcome, kind == .languageModel { return "\(name) · \(what) · key saved in your Keychain" }
        return "\(name) key accepted · saved in your Keychain"
    }

    /// " · claude-sonnet-5-5": the model the language model step will use.
    private func modelSuffix(_ name: String) -> String {
        guard kind == .languageModel, let provider = detected?.kind,
              let model = model.llmModel ?? model.preselectedModel(provider) else { return "" }
        return " · \(model)"
    }

    /// "Need a Soniox key? Get one · $200 credit ↗", with the provider's real
    /// free offer if any.
    private func offerLine(_ provider: OnboardingKeyProvider) -> String {
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
                let open = (!server && shown?.kind == provider.kind) || hoveredLogo == provider.kind
                let dimmed = detected != nil && !open
                Button {
                    if server { backToKeys() }
                    picked = picked == provider.kind && draft.isEmpty ? nil : provider.kind
                    setCurrent(provider.kind)
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
                .accessibilityAddTraits(!server && shown?.kind == provider.kind ? [.isButton, .isSelected] : .isButton)
            }
            serverMark
        }
        .frame(height: 36)
        .animation(OnboardingMotion.resolve(.spring(response: 0.28, dampingFraction: 0.86), reduceMotion: reduceMotion),
                   value: hoveredLogo)
        .animation(OnboardingMotion.resolve(.spring(response: 0.28, dampingFraction: 0.86), reduceMotion: reduceMotion),
                   value: shown?.kind)
        .animation(OnboardingMotion.resolve(.spring(response: 0.28, dampingFraction: 0.86), reduceMotion: reduceMotion),
                   value: hoveredServer)
    }

    /// "Self-hosted": an OpenAI-compatible server, a mark in the same row,
    /// monochrome and of the marks' optical height; named on hover and
    /// while its fields are shown.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    private var serverMark: some View {
        let open = server || hoveredServer
        return Button {
            if !server { model.useOwnServer(kind) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(OnboardingTheme.ink)
                    .frame(width: 20, height: 20)
                    .opacity(open ? 1 : detected != nil ? 0.24 : 0.46)
                if open {
                    Text("Self-hosted")
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
        .onHover { hoveredServer = $0 }
        .help(kind.serverHelp)
        .accessibilityLabel("Self-hosted server")
        .accessibilityAddTraits(server ? [.isButton, .isSelected] : .isButton)
    }

    private static func monoWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private var border: Color {
        if accepted { return OnboardingTheme.green.opacity(0.55) }
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
        if key.isEmpty, outcome.isDone {
            // Return on an accepted key goes on (with the model it shows).
            if model.dwell.isCounting || model.dwell.isLatched { model.dwell.commitNow() } else { model.next() }
            return
        }
        if key.isEmpty {
            // An empty field uses the key already saved for this step.
            guard saved, !outcome.isDone else { return }
            use("", provider: current)
            return
        }
        // Nobody named: neither the key's format nor a picked mark.
        guard let provider = known?.kind else { return model.rejectUnrecognizedKey(on: step) }
        setCurrent(provider)
        use(key, provider: provider)
    }

    private func use(_ key: String, provider: AIProviderKind) {
        let step = self.step
        Task {
            if kind == .speech {
                await model.useSpeechKey(key, provider: provider)
            } else {
                await model.useLLMKey(key, provider: provider)
            }
            if model.outcome(step).isDone { draft = "" }
        }
    }

    /// A failed check keeps the key in the field; a new answer clears the
    /// hand-picked mark only when the check succeeded.
    private func react(to outcome: OnboardingStepOutcome) {
        if outcome.isDone { picked = nil }
    }
}

/// The model of an accepted key: one quiet line, "Model  claude-sonnet-5-5 ⌄
/// $2 / $10 per 1M  Recommended", opening a small dark list of the provider's current
/// models with their prices. No chip, no extra step. (A native menu drew only
/// "Model": AppKit keeps one text of a menu's label.)
struct OnboardingModelMenu: View {
    let choices: [OnboardingModelChoice]
    let selected: String?
    /// Marked "Recommended" in the line and the list.
    let recommended: String?
    /// The person picked a model: the button names it instead of asking.
    var picked = false
    let busy: Bool
    /// The list opened, or closed without a pick.
    var opened: (Bool) -> Void = { _ in }
    let pick: (String) -> Void
    @State private var hovered = false
    @State private var open = false
    @State private var picking = false

    var body: some View {
        Button { open.toggle() } label: {
            // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
            // The owner: "after the key, Choose model, and there the
            // Recommended tag"; once a model is picked the button names it
            // ("Claude Sonnet 5.5 ⌄"), never cut and without its price.
            HStack(spacing: 6) {
                Text(picked ? selected.map(OnboardingModelPick.readableName) ?? "Choose model" : "Choose model")
                    .foregroundColor(OnboardingTheme.ink)
                    .fixedSize()
                Image(systemName: busy ? "ellipsis" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(OnboardingTheme.muted)
            }
            .font(OnboardingTheme.sans(12))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(hovered || open ? 0.08 : 0.04)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(hovered || open ? 0.12 : 0.06), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(busy)
        .onHover { hovered = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
        .onChange(of: open) { _, isOpen in
            if isOpen { picking = false; opened(true) } else if !picking { opened(false) }
        }
        .help(picked ? (selected ?? "") : "The recommended model is set; pick another of this provider's current models")
        .accessibilityLabel(picked ? "Model, \(selected.map(OnboardingModelPick.readableName) ?? "none")"
                            : "Choose model, \(selected.map(OnboardingModelPick.readableName) ?? "none") set")
    }

    private var list: some View {
        OnboardingModelList(choices: choices, selected: selected, recommended: recommended) { id in
            picking = true
            open = false
            pick(id)
        }
    }
}

/// The "Choose model" list: readable names with the ID under each, the
/// recommended one tagged, prices on the right.
struct OnboardingModelList: View {
    let choices: [OnboardingModelChoice]
    let selected: String?
    let recommended: String?
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(choices) { choice in
                OnboardingModelRow(choice: choice, isSelected: choice.id == selected,
                                   isRecommended: choice.id == recommended) { pick(choice.id) }
            }
        }
        .padding(6)
        // As wide as the longest name needs, within the window.
        .fixedSize()
        .frame(minWidth: 280, maxWidth: 480)
        .background(Color(red: 0.086, green: 0.086, blue: 0.098))
        .preferredColorScheme(.dark)
    }
}

private struct OnboardingModelRow: View {
    let choice: OnboardingModelChoice
    let isSelected: Bool
    let isRecommended: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            // The readable name never shortens; the ID sits small under it
            // and "Recommended" is a small tag beside the name.
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(OnboardingModelPick.readableName(choice.id))
                            .font(OnboardingTheme.sans(13, weight: .medium))
                            .foregroundColor(OnboardingTheme.ink)
                            .fixedSize()
                        if isRecommended {
                            Text("RECOMMENDED")
                                .font(OnboardingTheme.sans(8.5, weight: .semibold))
                                .tracking(0.4)
                                .foregroundColor(OnboardingTheme.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(OnboardingTheme.green.opacity(0.14)))
                                .fixedSize()
                        }
                    }
                    Text(choice.id)
                        .font(OnboardingTheme.mono(10.5))
                        .foregroundColor(OnboardingTheme.faint)
                        .fixedSize()
                }
                Spacer(minLength: 16)
                if let price = choice.price {
                    Text(price)
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(OnboardingTheme.muted)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension OnboardingStepOutcome {
    var failureText: String? { if case .failed(let text) = self { return text } else { return nil } }
}
