import AppKit
import SwiftUI

// The whytap.ai wireframe language of the first two steps (design pass of
// 2026-11-22, draft): a laptop and a key drawn as depth-sorted wire solids.
// Hovered, a figure comes to the front and the other recedes along the depth
// axis, dimmer and without its caption.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

/// The wire palette: silver wire with a rose tint toward the viewer, on the
/// onboarding's dark ground.
enum OnboardingWireframeInk {
    static let wire: (Double, Double, Double) = (0.949, 0.945, 0.965)
    static let rose: (Double, Double, Double) = (0.949, 0.463, 0.714)
    static let roseColor = Color(red: rose.0, green: rose.1, blue: rose.2)
    static let veil = Color(red: 0.071, green: 0.071, blue: 0.086)
    /// The ground: lighter at the centre, the window's own colour at the edge.
    static let groundCenter = Color(red: 0.098, green: 0.098, blue: 0.118)
}

// MARK: - Wire solid

struct OnboardingWireSolid {
    struct Vec3 { var x: Double; var y: Double; var z: Double }

    let vertices: [Vec3]
    let edges: [(Int, Int)]
    let dotIndices: [Int]
    let inkWeight: Double

    static let cameraDistance: Double = 4.0
    static let depthLevels = 6

    init(rawVertices: [Vec3], edges: [(Int, Int)], dotIndices: [Int]) {
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
    }

    static func apparentRadius(_ radius: Double, worldZ: Double) -> Double {
        radius * (cameraDistance / max(1.2, cameraDistance - worldZ))
    }

    /// Draws back to front in depth buckets; `lit` warms the near wires toward
    /// rose and lays a soft veil behind the figure (no glow band).
    func draw(in context: inout GraphicsContext, center: CGPoint, worldZ: Double, radius: Double,
              angles: (ax: Double, ay: Double, az: Double), fade: Double, lit: Double) {
        guard fade > 0.01 else { return }
        let cx = cos(angles.ax), sx = sin(angles.ax)
        let cy = cos(angles.ay), sy = sin(angles.ay)
        let cz = cos(angles.az), sz = sin(angles.az)
        let m0 = cz * cy, m1 = cz * sy * sx - sz * cx, m2 = cz * sy * cx + sz * sx
        let m3 = sz * cy, m4 = sz * sy * sx + cz * cx, m5 = sz * sy * cx - cz * sx
        let m6 = -sy, m7 = cy * sx, m8 = cy * cx

        var projected = [(pt: CGPoint, d: Double)](repeating: (.zero, 0), count: vertices.count)
        var meanX = 0.0, meanY = 0.0
        for i in vertices.indices {
            let v = vertices[i]
            let qx = m0 * v.x + m1 * v.y + m2 * v.z
            let qy = m3 * v.x + m4 * v.y + m5 * v.z
            let qz = m6 * v.x + m7 * v.y + m8 * v.z
            let k = Self.cameraDistance / max(1.2, Self.cameraDistance - (worldZ + qz * 0.55))
            let point = CGPoint(x: center.x + qx * k * radius, y: center.y + qy * k * radius)
            meanX += point.x
            meanY += point.y
            projected[i] = (point, min(1, max(-1, qz * 0.78 + worldZ * 0.28)))
        }
        meanX /= Double(max(1, vertices.count))
        meanY /= Double(max(1, vertices.count))
        let apparent = Self.apparentRadius(radius, worldZ: worldZ)
        let fine = min(1.14, max(0.58, apparent / 68))

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
        var dotPaths = [Path](repeating: Path(), count: Self.depthLevels)
        for (a, b) in edges {
            let level = bucket((projected[a].d + projected[b].d) * 0.5)
            edgePaths[level].move(to: projected[a].pt)
            edgePaths[level].addLine(to: projected[b].pt)
        }
        for index in dotIndices {
            let level = bucket(projected[index].d)
            let t = (Double(level) + 0.5) / Double(Self.depthLevels)
            let r = (0.82 + 1.35 * t + lit * 0.34 * t) * fine
            let p = projected[index].pt
            dotPaths[level].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        let base = OnboardingWireframeInk.wire, rose = OnboardingWireframeInk.rose
        for level in 0..<Self.depthLevels {
            let t = (Double(level) + 0.5) / Double(Self.depthLevels)
            let mix = lit * pow(t, 2.2) * 0.52
            let color = (base.0 + (rose.0 - base.0) * mix, base.1 + (rose.1 - base.1) * mix, base.2 + (rose.2 - base.2) * mix)
            if !edgePaths[level].isEmpty {
                let alpha = min(0.95, (0.11 + 0.50 * t + lit * 0.16 * t) * inkWeight * fade)
                context.stroke(edgePaths[level], with: .color(Color(red: color.0, green: color.1, blue: color.2, opacity: alpha)),
                               style: StrokeStyle(lineWidth: (0.56 + 0.95 * t + lit * 0.22 * t) * fine, lineCap: .round, lineJoin: .round))
            }
            if !dotPaths[level].isEmpty {
                let alpha = min(0.98, (0.30 + 0.54 * t + lit * 0.18) * (0.65 + 0.35 * inkWeight) * fade)
                context.fill(dotPaths[level], with: .color(Color(red: color.0, green: color.1, blue: color.2, opacity: alpha)))
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
        let rTL = pt(-hw + 0.015, yTop + dy + ny, zBack + dz + nz, dot: true)
        let rTR = pt(hw - 0.015, yTop + dy + ny, zBack + dz + nz, dot: true)
        let rBL = pt(-hw + 0.015, yTop + ny, zBack + nz), rBR = pt(hw - 0.015, yTop + ny, zBack + nz)
        e.append(contentsOf: [(rBL, rTL), (rTL, rTR), (rTR, rBR), (lTL, rTL), (lTR, rTR)])
        func screen(_ x: Double, _ u: Double) -> Int { pt(x, yTop + dy * u, zBack + dz * u) }
        let sBL = screen(-hw + 0.07, 0.08), sBR = screen(hw - 0.07, 0.08)
        let sTL = screen(-hw + 0.07, 0.92), sTR = screen(hw - 0.07, 0.92)
        let n1 = screen(-0.11, 0.92), n2 = screen(-0.095, 0.865), n3 = screen(0.095, 0.865), n4 = screen(0.11, 0.92)
        e.append(contentsOf: [(sBL, sBR), (sBR, sTR), (sTL, sBL), (sTL, n1), (n1, n2), (n2, n3), (n3, n4), (n4, sTR)])
        return OnboardingWireSolid(rawVertices: v, edges: e, dotIndices: dots)
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
}

// MARK: - Step 1: how should Whytap hear you

/// On this Mac or API keys as two wire figures. Hover brings one forward;
/// a click (or the figure's button for keyboard and VoiceOver) chooses it.
struct OnboardingSourceStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: OnboardingSpeechSource?
    @State private var keyTurn = 0.0

    private struct Pose { var x: Double; var y: Double; var z: Double; var fade: Double; var lit: Double }

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

    private var chosen: OnboardingSpeechSource? { model.progress.source }
    private var offersLaptop: Bool { model.start.onDeviceSupported }

    private func stage(_ size: CGSize) -> some View {
        let focus = hovered ?? chosen
        let laptop = pose(.onThisMac, focus: focus, size: size)
        let key = pose(.yourKey, focus: focus, size: size)
        let radius = min(64, size.height * 0.24)
        return ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 1.35 : timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, _ in
                    let drawLaptop = { (context: inout GraphicsContext) in
                        guard offersLaptop else { return }
                        OnboardingWireCatalog.laptop.draw(
                            in: &context, center: CGPoint(x: laptop.x, y: laptop.y), worldZ: laptop.z, radius: radius,
                            angles: (-0.34 + (reduceMotion ? 0 : cos(t * 0.48) * 0.065), 0.40 + (reduceMotion ? 0 : sin(t * 0.62) * 0.14), 0),
                            fade: laptop.fade, lit: laptop.lit)
                    }
                    let drawKey = { (context: inout GraphicsContext) in
                        OnboardingWireCatalog.key.draw(
                            in: &context, center: CGPoint(x: key.x, y: key.y), worldZ: key.z, radius: radius,
                            angles: (-0.26 + keyTurn + (reduceMotion ? 0 : cos(t * 0.72 + 0.6) * 0.22),
                                     -0.44 + (reduceMotion ? 0 : sin(t * 0.56 + 1.4) * 0.15), 0.38),
                            fade: key.fade, lit: key.lit)
                    }
                    // Painter's order: the receded figure first.
                    if laptop.z <= key.z { drawLaptop(&context); drawKey(&context) } else { drawKey(&context); drawLaptop(&context) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if offersLaptop {
                caption(laptop, radius: radius, title: "On this Mac", detail: laptopDetail)
            }
            caption(key, radius: radius, title: "API keys", detail: keyDetail)

            HStack(spacing: 0) {
                if offersLaptop {
                    choiceButton(.onThisMac, label: "On this Mac. \(laptopDetail)")
                }
                choiceButton(.yourKey, label: "API keys. \(keyDetail)")
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(OnboardingMotion.resolve(.spring(response: 0.42, dampingFraction: 0.86), reduceMotion: reduceMotion), value: focus)
    }

    private var laptopDetail: String {
        switch onDevice.status {
        case .downloading(let fraction) where chosen == .onThisMac:
            return "Downloading the speech model · \(Int((fraction * 100).rounded()))%"
        case .ready where chosen == .onThisMac:
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

    private func pose(_ figure: OnboardingSpeechSource, focus: OnboardingSpeechSource?, size: CGSize) -> Pose {
        let w = size.width, midY = size.height * 0.40
        let left = w * 0.29, right = w * 0.71
        guard offersLaptop else { return Pose(x: w / 2, y: midY, z: focus == .yourKey ? 0.5 : 0, fade: 1, lit: focus == .yourKey ? 1 : 0) }
        let home = figure == .onThisMac ? left : right
        switch focus {
        case .none: return Pose(x: home, y: midY, z: 0, fade: 1, lit: 0)
        case .some(let f) where f == figure: return Pose(x: w / 2, y: midY + 2, z: 0.68, fade: 1, lit: 1)
        default: return Pose(x: figure == .onThisMac ? w * 0.30 : w * 0.70, y: midY - 30, z: -1.22, fade: 0.28, lit: 0)
        }
    }

    /// The title rides under its figure; a receded figure has no caption.
    private func caption(_ pose: Pose, radius: Double, title: String, detail: String) -> some View {
        let below = pose.y + OnboardingWireSolid.apparentRadius(radius, worldZ: pose.z) * 0.86 + 30
        let receded = pose.z < -0.2
        let detailOpacity = min(1, max(0, (pose.lit - 0.18) / 0.72))
        return VStack(spacing: 4) {
            Text(title)
                .font(OnboardingTheme.sans(14.5, weight: .medium))
                .foregroundColor(OnboardingTheme.ink)
            Text(detail)
                .font(OnboardingTheme.sans(12.5))
                .foregroundColor(OnboardingTheme.muted)
                .fixedSize()
                .opacity(detailOpacity)
                .offset(y: (1 - detailOpacity) * 4)
        }
        .scaleEffect(min(1.04, max(0.86, 1 + pose.z * 0.08)))
        .opacity(receded ? 0 : 1)
        .position(x: pose.x, y: below)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func choiceButton(_ figure: OnboardingSpeechSource, label: String) -> some View {
        Button {
            if figure == .yourKey, !reduceMotion {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { keyTurn += .pi * 0.5 }
            }
            figure == .onThisMac ? model.chooseOnThisMac() : model.chooseYourKey()
        } label: {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            if inside { hovered = figure } else if hovered == figure { hovered = nil }
        }
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
    @State private var keyTurn = 0.0
    @State private var keyShift = 0.0

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
            if accepted { keyTurn = .pi * 0.5 }
        }
    }

    private var wireKey: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion && !checking)) { timeline in
            let t = reduceMotion ? 1.1 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                OnboardingWireCatalog.key.draw(
                    in: &context, center: CGPoint(x: size.width / 2 + keyShift, y: size.height / 2), worldZ: 0, radius: 40,
                    angles: (-0.20 + keyTurn + (reduceMotion ? 0 : cos(t * 0.46) * 0.05), -0.40 + (reduceMotion ? 0 : sin(t * 0.58) * 0.08), 0.03),
                    fade: 1, lit: checking ? 0.85 : accepted ? 0.6 : 0)
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
        let spring = OnboardingMotion.resolve(.spring(response: 0.34, dampingFraction: 0.84), reduceMotion: reduceMotion)
        switch outcome {
        case .working:
            withAnimation(spring) { keyShift = 18 }
        case .done:
            withAnimation(spring) { keyShift = 0; keyTurn = .pi * 0.5 }
        case .failed:
            withAnimation(spring) { keyShift = 0 }
            guard !reduceMotion, let problem, [.refused, .noCredit, .noSpeechAccess].contains(problem) else { return }
            // The key catches on a pin, then eases back.
            withAnimation(.spring(response: 0.20, dampingFraction: 0.78)) { keyTurn = problem == .noCredit ? 0.44 : 0.30 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { keyTurn = 0 }
            }
        case .idle:
            withAnimation(spring) { keyShift = 0; keyTurn = 0 }
        }
    }
}

extension OnboardingStepOutcome {
    var failureText: String? { if case .failed(let text) = self { return text } else { return nil } }
}
