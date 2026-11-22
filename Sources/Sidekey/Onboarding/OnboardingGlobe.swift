import AppKit
import simd
import SwiftUI

// The language step's wireframe globe (the design pass's screen 03): country
// outlines on a unit sphere, drawn like the key and the padlock (depth-shaded
// edges, vertex dots, light on the faces), turned by the mouse, and lit where
// a click or the typed text points.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

/// One country (or, in coarse data, a joined region) on the globe.
struct OnboardingGlobeCountry: Identifiable, Equatable {
    /// ISO 3166-1 alpha-2, or the joined codes of a region.
    let code: String
    let name: String
    /// ISO 639-1, most spoken first.
    let languages: [String]
    let lat: Double
    let lon: Double
    var id: String { code }

    static func == (a: Self, b: Self) -> Bool { a.code == b.code }
}

/// The globe's geometry, built once: every outline vertex on the unit
/// sphere, long edges subdivided along great circles so borders hug it.
final class OnboardingGlobeMesh {
    static let shared = OnboardingGlobeMesh(encoded: OnboardingGlobeCountries.encoded)

    private(set) var countries: [OnboardingGlobeCountry] = []
    /// Unit vectors (x right, y down, z towards the viewer at yaw 0).
    private(set) var vertices: [SIMD3<Double>] = []
    /// Each shared border once.
    private(set) var baseEdges: [(Int, Int)] = []
    private(set) var baseDots: [Int] = []
    private(set) var countryEdges: [[(Int, Int)]] = []
    private(set) var countryDots: [[Int]] = []
    /// The outline corners, for the click test.
    private(set) var hitRings: [[[SIMD3<Double>]]] = []
    private(set) var centers: [SIMD3<Double>] = []
    private(set) var graticule: [SIMD3<Double>] = []
    private(set) var graticuleEdges: [(Int, Int)] = []

    static func point(lat: Double, lon: Double) -> SIMD3<Double> {
        let phi = lat * .pi / 180, lambda = lon * .pi / 180
        return SIMD3(cos(phi) * sin(lambda), -sin(phi), cos(phi) * cos(lambda))
    }

    init(encoded: String) {
        var seen = Set<SIMD3<Int>>()
        for line in encoded.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 5 else { continue }
            let center = fields[3].split(separator: ",").compactMap { Double($0) }
            guard center.count == 2 else { continue }
            let rings: [[SIMD3<Double>]] = fields[4].split(separator: ";").map { ring in
                ring.split(separator: " ").compactMap { pair in
                    let latLon = pair.split(separator: ",").compactMap { Double($0) }
                    return latLon.count == 2 ? Self.point(lat: latLon[0], lon: latLon[1]) : nil
                }
            }.filter { $0.count >= 3 }
            guard !rings.isEmpty else { continue }
            let code = String(fields[0])
            // The Mac's English name where it has one ("Côte d’Ivoire", not "Côte d'Ivoire").
            let name = code.count == 2 ? Locale(identifier: "en_US").localizedString(forRegionCode: code) : nil
            countries.append(OnboardingGlobeCountry(code: code, name: name ?? String(fields[1]),
                                                    languages: fields[2].split(separator: " ").map(String.init),
                                                    lat: center[0], lon: center[1]))
            centers.append(Self.point(lat: center[0], lon: center[1]))
            hitRings.append(rings)
            var edges: [(Int, Int)] = []
            var dots: [Int] = []
            for ring in rings {
                var indices: [Int] = []
                // Corner dots by distance along the coast, so a detailed
                // outline is not a string of beads: about every 7° (4° on
                // the lit country).
                var sinceDot = Double.infinity, sinceBaseDot = Double.infinity
                for (i, a) in ring.enumerated() {
                    let b = ring[(i + 1) % ring.count]
                    let angle = acos(max(-1, min(1, simd_dot(a, b)))) * 180 / .pi
                    let steps = max(1, Int(ceil(angle / 4.2)))
                    let start = vertices.count
                    vertices.append(a)
                    indices.append(start)
                    if sinceDot >= 4 { dots.append(start); sinceDot = 0 }
                    if sinceBaseDot >= 7 { baseDots.append(start); sinceBaseDot = 0 }
                    sinceDot += angle
                    sinceBaseDot += angle
                    for s in 1..<steps {
                        let f = Double(s) / Double(steps)
                        indices.append(vertices.count)
                        vertices.append(simd_normalize(a + (b - a) * f))
                    }
                }
                for (i, u) in indices.enumerated() {
                    let w = indices[(i + 1) % indices.count]
                    // Natural Earth cuts Russia and Fiji at 180°: no border there.
                    if Self.onDateline(vertices[u]), Self.onDateline(vertices[w]) { continue }
                    edges.append((u, w))
                    // A border two countries share is drawn once.
                    let key = SIMD3<Int>(Int(((vertices[u] + vertices[w]) * 220).x.rounded()),
                                         Int(((vertices[u] + vertices[w]) * 220).y.rounded()),
                                         Int(((vertices[u] + vertices[w]) * 220).z.rounded()))
                    if seen.insert(key).inserted { baseEdges.append((u, w)) }
                }
            }
            countryEdges.append(edges)
            countryDots.append(dots)
        }
        // Parallels and meridians every 30°: the sphere's volume.
        for lat in stride(from: -60.0, through: 60, by: 30) {
            let first = graticule.count
            for s in 0..<48 {
                graticule.append(Self.point(lat: lat, lon: -180 + 360 * Double(s) / 48))
                if s > 0 { graticuleEdges.append((graticule.count - 2, graticule.count - 1)) }
            }
            graticuleEdges.append((graticule.count - 1, first))
        }
        for lon in stride(from: -180.0, to: 180, by: 30) {
            for s in 0...32 {
                graticule.append(Self.point(lat: -80 + 160 * Double(s) / 32, lon: lon))
                if s > 0 { graticuleEdges.append((graticule.count - 2, graticule.count - 1)) }
            }
        }
    }

    private static func onDateline(_ v: SIMD3<Double>) -> Bool { abs(v.x) < 2e-3 && v.z < 0 }

    func index(of code: String) -> Int? { countries.firstIndex { $0.code == code } }

    /// The country under a point of the sphere: the smallest outline that
    /// contains it, otherwise the nearest coast within about 7°.
    func country(at p: SIMD3<Double>) -> Int? {
        var east = SIMD3(p.z, 0, -p.x)
        east = simd_length(east) < 1e-4 ? SIMD3(1, 0, 0) : simd_normalize(east)
        let north = simd_normalize(simd_cross(p, east))
        var inside: Int?
        var insideArea = Double.infinity
        var nearest: Int?
        var nearestDistance = 0.125
        for (index, rings) in hitRings.enumerated() {
            if simd_dot(centers[index], p) < -0.25, !["RU", "US", "CA"].contains(countries[index].code) { continue }
            for ring in rings {
                var near = 0
                var uv: [SIMD2<Double>] = []
                uv.reserveCapacity(ring.count)
                var low = SIMD2(Double.infinity, .infinity), high = SIMD2(-Double.infinity, -.infinity)
                for v in ring {
                    let d = simd_dot(v, p)
                    if d > 0.15 { near += 1 }
                    let point = SIMD2(simd_dot(v, east), simd_dot(v, north)) / max(0.25, d)
                    uv.append(point)
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
                guard near >= 3 else { continue }
                var crossing = false
                var j = uv.count - 1
                for i in uv.indices {
                    let a = uv[i], b = uv[j]
                    if (a.y > 0) != (b.y > 0), 0 < (b.x - a.x) * -a.y / (b.y - a.y) + a.x { crossing.toggle() }
                    let delta = b - a
                    let length = simd_length_squared(delta)
                    let t = length > 1e-8 ? max(0, min(1, -simd_dot(a, delta) / length)) : 0
                    let distance = simd_length(a + delta * t)
                    if distance < nearestDistance { nearestDistance = distance; nearest = index }
                    j = i
                }
                if crossing {
                    let area = (high.x - low.x) * (high.y - low.y)
                    if area < insideArea { insideArea = area; inside = index }
                }
            }
        }
        return inside ?? nearest
    }
}

// MARK: - Variants

/// A variant of a language the globe offers under it, like the prototype:
/// English US / UK / AU, Portuguese BR / PT, Spanish ES / MX. Shown with
/// every speech route; it is stored beside the language and providers keep
/// getting the language's own code (the owner, REV 51).
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingLanguageVariant: Equatable, Identifiable {
    /// The language's ISO 639-1 code.
    let language: String
    /// "UK", "BR": shown small after the label.
    let code: String
    /// In the language itself: "United Kingdom", "Brasil", "México".
    let label: String
    /// BCP 47: "en-GB".
    let tag: String
    /// Where it is spoken first, the country the globe lights for it.
    let country: String
    /// The other countries that speak this variant.
    let countries: Set<String>
    var id: String { tag }

    static let all: [OnboardingLanguageVariant] = [
        .init(language: "en", code: "US", label: "United States", tag: "en-US", country: "US",
              countries: ["US", "CA", "PH", "PR", "LR", "JM", "BS", "BZ", "TT", "GY"]),
        .init(language: "en", code: "UK", label: "United Kingdom", tag: "en-GB", country: "GB",
              countries: ["GB", "IE", "NG", "ZA", "NA_BW", "GH", "KE", "UG", "TZ", "ZM", "ZW", "IN", "PK", "SG",
                          "MT", "SL", "GM", "BW", "NA", "SZ", "LS", "MW", "SS", "SD", "MZ_ZW", "WA_REGION", "CM"]),
        .init(language: "en", code: "AU", label: "Australia", tag: "en-AU", country: "AU",
              countries: ["AU", "NZ", "PG", "FJ", "SB", "VU"]),
        .init(language: "pt", code: "BR", label: "Brasil", tag: "pt-BR", country: "BR", countries: ["BR"]),
        .init(language: "pt", code: "PT", label: "Portugal", tag: "pt-PT", country: "PT",
              countries: ["PT", "AO", "MZ", "GW", "TL", "MZ_ZW", "CD_AO"]),
        .init(language: "es", code: "ES", label: "España", tag: "es-ES", country: "ES", countries: ["ES", "GQ"]),
        .init(language: "es", code: "MX", label: "México", tag: "es-MX", country: "MX",
              countries: ["MX", "AR", "CO", "CL", "PE", "VE", "CU", "GT", "GT_PA", "HN", "SV", "NI", "CR", "PA",
                          "DO", "PR", "EC", "BO", "PY", "UY", "US"]),
    ]

    static func variants(of language: String) -> [OnboardingLanguageVariant] { all.filter { $0.language == language } }

    /// The variant spoken in a country, else the language's first.
    static func variant(of language: String, in country: String?) -> OnboardingLanguageVariant? {
        let options = variants(of: language)
        return options.first { $0.country == country } ?? options.first { country.map($0.countries.contains) ?? false }
            ?? options.first
    }
}

// MARK: - Search

/// What the typed text points to: a country, and the language when the text
/// named a language rather than the country.
struct OnboardingGlobeMatch: Equatable {
    let country: Int
    let language: String?
}

enum OnboardingGlobeSearch {
    /// Where a language is at home when the text names only the language.
    static let homes: [String: String] = [
        "en": "US", "es": "ES", "pt": "BR", "fr": "FR", "de": "DE", "ar": "SA", "zh": "CN", "ru": "RU",
        "hi": "IN", "bn": "BD", "ur": "PK", "ms": "MY", "sw": "KE", "nl": "NL", "it": "IT", "sr": "RS",
        "ca": "ES", "af": "ZA", "ta": "IN", "fa": "IR", "ko": "KR", "tr": "TR", "el": "GR", "sv": "SE",
    ]
    private static let aliases: [String: [String]] = [
        "GB": ["uk", "britain", "great britain", "england", "scotland", "wales", "british"],
        "US": ["usa", "america", "united states of america", "сша", "америка"],
        "RU": ["рф"], "AE": ["uae", "emirates"], "KR": ["korea"], "CZ": ["czechia"],
        "NL": ["holland"], "CI": ["ivory coast"],
    ]

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Country names in English, in their own languages and in the Mac's
    /// language; then the names of their languages.
    static func names(of country: OnboardingGlobeCountry) -> [String] {
        var names = [country.name]
        let region = country.code
        if region.count == 2 {
            for identifier in [Locale.current.identifier] + country.languages {
                if let name = Locale(identifier: identifier).localizedString(forRegionCode: region) { names.append(name) }
            }
        }
        names += aliases[region] ?? []
        return names
    }

    static func best(_ query: String, in mesh: OnboardingGlobeMesh = .shared,
                     languages: [AppLanguage] = AppLanguage.all) -> OnboardingGlobeMatch? {
        let q = fold(query)
        guard !q.isEmpty else { return nil }
        func score(_ term: String, _ rank: Double) -> Double {
            let term = fold(term)
            if term == q { return 100 - rank }
            if term.hasPrefix(q) { return 82 - min(20, Double(term.count - q.count)) - rank }
            if q.count >= 2, term.contains(q) { return 52 - rank }
            return -1
        }
        var best: OnboardingGlobeMatch?
        var bestScore = 39.0
        for (index, country) in mesh.countries.enumerated() {
            for (rank, name) in names(of: country).enumerated() {
                let s = score(name, Double(rank) * 0.5)
                if s > bestScore { bestScore = s; best = OnboardingGlobeMatch(country: index, language: nil) }
            }
        }
        // A language's name: its home country, with that language.
        for language in languages {
            let s = max(score(language.englishName, 0.2), score(language.displayName, 0.3), score(language.code, 4))
            guard s > bestScore else { continue }
            let home = homes[language.code].flatMap(mesh.index(of:))
                ?? mesh.countries.firstIndex { $0.languages.first == language.code }
                ?? mesh.countries.firstIndex { $0.languages.contains(language.code) }
            if let home { bestScore = s; best = OnboardingGlobeMatch(country: home, language: language.code) }
        }
        return best
    }

    /// The country a chosen language is shown on when the step is revisited.
    static func home(of code: String, in mesh: OnboardingGlobeMesh = .shared) -> Int? {
        homes[code].flatMap(mesh.index(of:))
            ?? mesh.countries.firstIndex { $0.languages.first == code }
            ?? mesh.countries.firstIndex { $0.languages.contains(code) }
    }
}

// MARK: - Motion

/// The globe's springs, stepped on every frame (the prototype's constants):
/// a slow idle turn, drag with inertia, a spring to the picked country, the
/// outline light of each country and a slight breath.
final class OnboardingGlobeMotion {
    /// Offscreen renders and tests: every spring lands at once.
    static var settlesAtOnce = false

    var yaw = -16 * Double.pi / 180
    var pitch = 24 * Double.pi / 180
    private var vYaw = 0.0, vPitch = 0.0
    private var target: (yaw: Double, pitch: Double)?
    private(set) var lit: [Double]
    private var vLit: [Double]
    private(set) var clock = 1.2
    private var last: TimeInterval?
    var dragging = false

    init(count: Int = OnboardingGlobeMesh.shared.countries.count) {
        lit = Array(repeating: 0, count: count)
        vLit = lit
    }

    /// Turns the globe to a country (its centre a little below the middle),
    /// or back to the idle turn.
    func aim(at country: OnboardingGlobeCountry?) {
        guard let country else { target = nil; return }
        target = (-country.lon * .pi / 180, max(-62, min(64, country.lat - 3)) * .pi / 180)
    }

    func drag(dx: Double, dy: Double, dt: Double) {
        target = nil
        yaw += dx * 0.0105
        pitch = max(-1.18, min(1.18, pitch + dy * 0.0095))
        vYaw = dx * 0.0105 / max(0.004, dt) * 0.55
        vPitch = dy * 0.0095 / max(0.004, dt) * 0.55
    }

    func stopSpin() { vYaw = 0; vPitch = 0 }

    func advance(to time: TimeInterval, still: Bool, lit goal: (Int) -> Double) {
        let still = still || Self.settlesAtOnce
        let dt = min(0.04, last.map { max(0, time - $0) } ?? 0.016)
        last = time
        if !still { clock += dt }
        if !dragging {
            if let target {
                let dYaw = (target.yaw - yaw + .pi * 3).truncatingRemainder(dividingBy: .pi * 2) - .pi
                if still {
                    yaw += dYaw; pitch = target.pitch; vYaw = 0; vPitch = 0
                } else {
                    vYaw = (vYaw + dYaw * 92 * dt) * exp(-14.2 * dt)
                    yaw += vYaw * dt
                    vPitch = (vPitch + (target.pitch - pitch) * 92 * dt) * exp(-14.2 * dt)
                    pitch += vPitch * dt
                }
            } else if !still {
                vYaw += (-0.052 - vYaw) * (1 - exp(-dt * 3.2))
                yaw += vYaw * dt
                let pitchGoal = 22 * Double.pi / 180 + sin(clock * 0.35) * 0.04
                vPitch = (vPitch + (pitchGoal - pitch) * 18 * dt) * exp(-6 * dt)
                pitch += vPitch * dt
            }
        }
        for i in lit.indices {
            let g = goal(i)
            if still {
                lit[i] = g; vLit[i] = 0
            } else {
                vLit[i] = (vLit[i] + (g - lit[i]) * 150 * dt) * exp(-18 * dt)
                lit[i] = max(0, min(1.15, lit[i] + vLit[i] * dt))
            }
        }
    }

    var breath: Double { Self.settlesAtOnce ? 1 : 1 + sin(clock * 0.85) * 0.011 }

    // MARK: Projection

    static let camera = 4.2

    struct Projected { var point: CGPoint; var q: SIMD3<Double> }

    func project(_ v: SIMD3<Double>, center: CGPoint, radius: Double) -> Projected {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let x1 = v.x * cy + v.z * sy
        let z1 = -v.x * sy + v.z * cy
        let q = SIMD3(x1, v.y * cp + z1 * sp, -v.y * sp + z1 * cp)
        let k = Self.camera / (Self.camera - q.z * 0.42)
        return Projected(point: CGPoint(x: center.x + q.x * k * radius, y: center.y + q.y * k * radius), q: q)
    }

    /// The point of the sphere under a point of the view, or nil off the disc.
    func unproject(_ point: CGPoint, center: CGPoint, radius: Double) -> SIMD3<Double>? {
        let u = (point.x - center.x) / radius, w = (point.y - center.y) / radius
        let r2 = u * u + w * w
        guard r2 <= 1.06 else { return nil }
        let qz = sqrt(1 - min(0.998, r2))
        let k = (Self.camera - qz * 0.42) / Self.camera
        let qx = u * k, qy = w * k
        let q = simd_normalize(SIMD3(qx, qy, sqrt(max(0.001, 1 - qx * qx - qy * qy))))
        let cp = cos(pitch), sp = sin(pitch)
        let y1 = q.y * cp - q.z * sp
        let z1 = q.y * sp + q.z * cp
        let cy = cos(yaw), sy = sin(yaw)
        return simd_normalize(SIMD3(q.x * cy - z1 * sy, y1, q.x * sy + z1 * cy))
    }
}

// MARK: - The globe

/// What the globe shows lit: the picked or matched country, its neighbours
/// in the same language (softer), the one under the pointer, and green once
/// the language is chosen.
struct OnboardingGlobeLight: Equatable {
    var active: Int?
    var siblings: [Int] = []
    var hovered: Int?
    var confirmed = false

    func goal(_ index: Int) -> Double {
        if index == active { return 1 }
        if siblings.contains(index) { return 0.42 }
        if index == hovered { return 0.62 }
        return 0
    }
}

struct OnboardingGlobe: View {
    let motion: OnboardingGlobeMotion
    let light: OnboardingGlobeLight
    /// A click (not a drag) on a country.
    let pick: (Int) -> Void
    let hover: (Int?) -> Void
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastDrag: (point: CGPoint, time: Date)?
    @State private var travelled = 0.0

    private static let mesh = OnboardingGlobeMesh.shared
    static let radius = 68.0

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            TimelineView(.animation) { timeline in
                Canvas { context, _ in
                    motion.advance(to: timeline.date.timeIntervalSinceReferenceDate, still: reduceMotion,
                                   lit: light.goal)
                    draw(in: &context, center: center)
                }
            }
            .contentShape(Circle().inset(by: max(0, proxy.size.height / 2 - Self.radius - 8)))
            .gesture(drag(center: center))
            .onContinuousHover { phase in
                guard enabled, !motion.dragging else { return }
                switch phase {
                case .active(let point):
                    hover(motion.unproject(point, center: center, radius: Self.radius).flatMap(Self.mesh.country(at:)))
                case .ended:
                    hover(nil)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Globe")
        .accessibilityValue(light.active.map { Self.mesh.countries[$0].name } ?? "No country picked")
        .accessibilityHint("Drag to turn it, click your country, or type it in the field below")
    }

    private func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard enabled else { return }
                let now = Date()
                if let last = lastDrag {
                    let dx = value.location.x - last.point.x, dy = value.location.y - last.point.y
                    travelled += hypot(dx, dy)
                    if travelled >= 5.5 {
                        motion.dragging = true
                        motion.drag(dx: dx, dy: dy, dt: now.timeIntervalSince(last.time))
                        hover(nil)
                    }
                } else {
                    travelled = 0
                }
                lastDrag = (value.location, now)
            }
            .onEnded { value in
                defer { lastDrag = nil; motion.dragging = false }
                guard enabled, travelled < 5.5,
                      let p = motion.unproject(value.location, center: center, radius: Self.radius),
                      let index = Self.mesh.country(at: p) else { return }
                motion.stopSpin()
                pick(index)
            }
    }

    // MARK: Drawing

    private typealias RGB = (Double, Double, Double)
    private static let ink: RGB = (242 / 255, 241 / 255, 246 / 255)
    private static let rose: RGB = (238 / 255, 156 / 255, 198 / 255)
    private static let green: RGB = (111 / 255, 207 / 255, 151 / 255)

    private static func color(_ rgb: RGB, _ alpha: Double) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2).opacity(alpha)
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// A segment from front to back is cut at the rim.
    private static func addFront(_ a: OnboardingGlobeMotion.Projected, _ b: OnboardingGlobeMotion.Projected,
                                 to path: inout Path, center: CGPoint, radius: Double) {
        if a.q.z >= 0, b.q.z >= 0 {
            path.move(to: a.point); path.addLine(to: b.point); return
        }
        if a.q.z < 0, b.q.z < 0 { return }
        let f = a.q.z / (a.q.z - b.q.z)
        let rim = CGPoint(x: center.x + (a.q.x + (b.q.x - a.q.x) * f) * radius,
                          y: center.y + (a.q.y + (b.q.y - a.q.y) * f) * radius)
        if a.q.z >= 0 { path.move(to: a.point); path.addLine(to: rim) } else { path.move(to: rim); path.addLine(to: b.point) }
    }

    private func draw(in context: inout GraphicsContext, center: CGPoint) {
        let mesh = Self.mesh
        let radius = Self.radius * motion.breath
        let spec = light.confirmed ? Self.green : Self.rose
        let points = mesh.vertices.map { motion.project($0, center: center, radius: radius) }
        let grid = mesh.graticule.map { motion.project($0, center: center, radius: radius) }
        let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        func stroke(_ path: Path, _ color: Color, _ width: Double) {
            var style = round
            style.lineWidth = width
            context.stroke(path, with: .color(color), style: style)
        }

        // The rim, with a grazing glint on two arcs.
        let limb = radius * OnboardingGlobeMotion.camera / sqrt(pow(OnboardingGlobeMotion.camera, 2) - 0.42 * 0.42)
        let disc = Path(ellipseIn: CGRect(x: center.x - limb, y: center.y - limb, width: limb * 2, height: limb * 2))
        stroke(disc, Self.color(Self.ink, 0.14), 0.85)
        context.stroke(disc, with: .linearGradient(
            Gradient(stops: [.init(color: Self.color(spec, 0.34), location: 0), .init(color: .clear, location: 0.45),
                             .init(color: .clear, location: 0.75), .init(color: Self.color(spec, 0.22), location: 1)]),
            startPoint: CGPoint(x: center.x - limb, y: center.y - limb),
            endPoint: CGPoint(x: center.x + limb, y: center.y + limb)), lineWidth: 1.05)

        // Parallels and meridians: faint behind, delicate in front.
        var gridBack = Path(), gridFront = Path()
        for (a, b) in mesh.graticuleEdges {
            let pa = grid[a], pb = grid[b]
            if pa.q.z < 0, pb.q.z < 0 { gridBack.move(to: pa.point); gridBack.addLine(to: pb.point) }
            if pa.q.z >= 0, pb.q.z >= 0 { gridFront.move(to: pa.point); gridFront.addLine(to: pb.point) }
        }
        stroke(gridBack, Self.color(Self.ink, 0.032), 0.48)
        stroke(gridFront, Self.color(Self.ink, 0.072), 0.48)

        // Outlines by depth, with light glancing off the coasts.
        let levels = 6
        var buckets = Array(repeating: Path(), count: levels)
        var dots = Array(repeating: Path(), count: levels)
        var glints = [Path(), Path()]
        var back = Path()
        var light = SIMD3(-0.46 + sin(motion.clock * 0.55) * 0.12, -0.44 + cos(motion.clock * 0.42) * 0.10, 0.76)
        light = simd_normalize(light)
        let half = simd_normalize(light + SIMD3(0, 0, 1))
        for (ia, ib) in mesh.baseEdges {
            let a = points[ia], b = points[ib]
            if a.q.z < 0, b.q.z < 0 { back.move(to: a.point); back.addLine(to: b.point); continue }
            let midZ = max(0, (a.q.z + b.q.z) / 2)
            let level = min(levels - 1, Int(midZ * Double(levels)))
            Self.addFront(a, b, to: &buckets[level], center: center, radius: radius)
            guard a.q.z > 0.08, b.q.z > 0.08 else { continue }
            let tangent = b.q - a.q
            let along = simd_dot(tangent, half) / max(1e-9, simd_length(tangent))
            let normal = (a.q + b.q) / 2
            let facing = simd_dot(normal, light)
            guard facing > 0.15 else { continue }
            let glint = facing * pow(sqrt(max(0, 1 - along * along)), 8) * midZ
            if glint > 0.42 { glints[1].move(to: a.point); glints[1].addLine(to: b.point) }
            else if glint > 0.22 { glints[0].move(to: a.point); glints[0].addLine(to: b.point) }
        }
        for index in mesh.baseDots {
            let a = points[index]
            guard a.q.z >= 0.02 else { continue }
            let level = min(levels - 1, Int(a.q.z * Double(levels)))
            let t = (Double(level) + 0.5) / Double(levels)
            let r = 0.68 + 0.72 * t
            dots[level].addEllipse(in: CGRect(x: a.point.x - r, y: a.point.y - r, width: r * 2, height: r * 2))
        }
        stroke(back, Self.color(Self.ink, 0.068), 0.5)
        let dim = self.light.active == nil ? 1.0 : 0.72
        for level in 0..<levels {
            let t = (Double(level) + 0.5) / Double(levels)
            stroke(buckets[level], Self.color(Self.ink, (0.14 + 0.36 * t) * dim), 0.52 + 0.54 * t)
            context.fill(dots[level], with: .color(Self.color(Self.ink, (0.20 + 0.42 * t) * dim)))
        }
        for (i, path) in glints.enumerated() {
            let st = i == 0 ? 0.30 : 0.58
            stroke(path, Self.color(Self.mix(Self.ink, spec, 0.55 + 0.35 * st), (0.18 + st * 0.30) * dim), 0.78 + st * 0.35)
        }

        // The lit countries: a soft bloom, a collar, a bright core, lit corners.
        for (index, level) in motion.lit.enumerated() where level > 0.015 {
            var outline = Path()
            for (ia, ib) in mesh.countryEdges[index] {
                Self.addFront(points[ia], points[ib], to: &outline, center: center, radius: radius)
            }
            guard !outline.isEmpty else { continue }
            let core = Self.mix(Self.ink, spec, 0.68)
            stroke(outline, Self.color(spec, 0.085 * level), 5.6)
            stroke(outline, Self.color(spec, 0.21 * level), 2.4)
            stroke(outline, Self.color(core, 0.94 * level), 1.22)
            var halos = Path(), nodes = Path()
            for d in mesh.countryDots[index] {
                let p = points[d]
                guard p.q.z >= 0.02 else { continue }
                halos.addEllipse(in: CGRect(x: p.point.x - 3.4, y: p.point.y - 3.4, width: 6.8, height: 6.8))
                nodes.addEllipse(in: CGRect(x: p.point.x - 1.42, y: p.point.y - 1.42, width: 2.84, height: 2.84))
            }
            context.fill(halos, with: .color(Self.color(spec, 0.18 * level)))
            context.fill(nodes, with: .color(Self.color(core, 0.96 * level)))
        }
    }
}
