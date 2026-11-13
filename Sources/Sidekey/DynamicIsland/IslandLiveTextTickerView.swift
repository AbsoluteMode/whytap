import AppKit
import SwiftUI

/// The live transcript of the recording wing: the line moves at the speaker's
/// rate and each new character gathers from dust flying in ahead of the text.
/// One line, the tail visible, same font as the other wing faces. The same for
/// every provider: it sees only the text.
/// WHY: .project-docs/decisions/2026-11-13-live-text-sand.md
struct IslandLiveTextTicker: View {
    let text: String

    @State private var model = IslandLiveTextTickerModel()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                model.draw(in: &context, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .onAppear { model.prime(text, now: Date.now.timeIntervalSinceReferenceDate) }
        .onChange(of: text) { _, next in
            model.textArrived(next, now: Date.now.timeIntervalSinceReferenceDate)
        }
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

/// Drawing state of one ticker. A reference type so the canvas can advance it
/// every frame without invalidating the view.
final class IslandLiveTextTickerModel {
    static let fontSize: CGFloat = 12
    static let textOpacity: Double = 0.9
    /// Dust per character.
    static let grains = 14
    /// Width of the fade where the line leaves the wing on the left.
    static let leadingFade: CGFloat = 10

    private var ticker = LiveTextTicker()
    /// Left edge of every character, plus the end of the last one.
    private var edges: [CGFloat] = [0]
    private var widths: [Character: CGFloat] = [:]
    private let font = NSFont.systemFont(ofSize: IslandLiveTextTickerModel.fontSize, weight: .medium)

    func prime(_ text: String, now: TimeInterval) {
        ticker.prime(text, now: now)
        measure()
    }

    func textArrived(_ text: String, now: TimeInterval) {
        ticker.textArrived(text, now: now)
        measure()
    }

    private func measure() {
        edges = [0]
        edges.reserveCapacity(ticker.characters.count + 1)
        var x: CGFloat = 0
        for character in ticker.characters {
            x += width(of: character)
            edges.append(x)
        }
    }

    private func width(of character: Character) -> CGFloat {
        if let known = widths[character] { return known }
        let measured = NSAttributedString(string: String(character), attributes: [.font: font]).size().width
        widths[character] = measured
        return measured
    }

    func draw(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        ticker.advance(now: now)
        let count = min(ticker.revealedCount, ticker.characters.count)
        guard count > 0 else { return }
        let fraction = CGFloat(ticker.revealed - Double(count))
        let nextWidth = count < ticker.characters.count ? edges[count + 1] - edges[count] : 0
        let offset = min(0, size.width - (edges[count] + fraction * nextWidth))
        let middle = size.height / 2

        var first = count - 1
        while first > 0, edges[first] + offset > -24 { first -= 1 }

        context.drawLayer { layer in
            for index in first..<count {
                let character = ticker.characters[index]
                guard !character.isWhitespace else { continue }
                let progress = ticker.gatherProgress(at: index, now: now)
                let x = edges[index] + offset
                let solid = Self.smooth((progress - 0.5) / 0.5)
                if solid > 0.01 {
                    layer.opacity = solid * Self.textOpacity
                    layer.draw(
                        Text(String(character))
                            .font(.system(size: Self.fontSize, weight: .medium))
                            .foregroundColor(.white),
                        at: CGPoint(x: x, y: middle), anchor: .leading
                    )
                }
                if progress < 1 {
                    drawGrains(
                        in: &layer, index: index, progress: progress,
                        origin: CGPoint(x: x, y: middle), width: edges[index + 1] - edges[index],
                        height: size.height
                    )
                }
            }
            guard offset < 0 else { return }
            layer.opacity = 1
            layer.blendMode = .destinationOut
            layer.fill(
                Path(CGRect(x: 0, y: 0, width: Self.leadingFade, height: size.height)),
                with: .linearGradient(
                    Gradient(colors: [.black, .black.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: Self.leadingFade, y: 0)
                )
            )
        }
    }

    /// The dust of one character: every grain starts ahead of the text (to the
    /// right), scattered over the wing's height, and lands inside the glyph.
    /// Positions come from the character's index, so nothing is stored.
    private func drawGrains(
        in layer: inout GraphicsContext, index: Int, progress: Double,
        origin: CGPoint, width: CGFloat, height: CGFloat
    ) {
        var random = GrainRandom(seed: UInt64(truncatingIfNeeded: index))
        for _ in 0..<Self.grains {
            let home = CGPoint(x: origin.x + random.next() * width, y: origin.y + (random.next() - 0.5) * 8)
            let start = CGPoint(
                x: origin.x + 16 + random.next() * 70,
                y: origin.y + (random.next() - 0.5) * height * 1.1
            )
            let delay = random.next() * 0.3
            let bend = (random.next() - 0.5) * 14
            let grain = 0.6 + random.next() * 0.9
            let local = min(1, max(0, (progress - delay) / (1 - delay)))
            guard local > 0 else { continue }
            let eased = 1 - pow(1 - local, 3)
            let point = CGPoint(
                x: start.x + (home.x - start.x) * eased,
                y: start.y + (home.y - start.y) * eased + sin(eased * .pi) * bend
            )
            let diameter = grain * (1.5 - eased * 0.8) + 0.6
            layer.opacity = Self.smooth(local / 0.2) * (1 - Self.smooth((progress - 0.75) / 0.25)) * 0.9
            layer.fill(
                Path(ellipseIn: CGRect(
                    x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter
                )),
                with: .color(.white)
            )
        }
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

/// SplitMix64: the same grains for the same character on every frame.
private struct GrainRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03
    }

    mutating func next() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(1 << 53)
    }
}
