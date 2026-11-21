import AppKit
import SwiftUI

/// The live transcript of the recording wing: the line moves at the speaker's
/// rate and each new character gathers from dust flying in ahead of the text.
/// One line, the tail visible, same font as the other wing faces. The same for
/// every provider: it sees only the text.
/// WHY: .project-docs/decisions/2026-11-13-live-text-sand.md
struct IslandLiveTextTicker: View {
    let text: String
    let visibleWidth: CGFloat
    let onRevealedWidthChange: (CGFloat) -> Void

    @State private var model = IslandLiveTextTickerModel()

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let revealedWidth = model.advance(now: now)
            Canvas { context, size in
                model.draw(in: &context, size: size, now: now, visibleWidth: visibleWidth)
            }
            .onChange(of: revealedWidth, initial: true) { _, width in
                onRevealedWidthChange(width)
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
    /// What is left of a scroll change caused by a rewrite: the whole line,
    /// later words included, glides to its new place.
    private var slide: CGFloat = 0
    /// What is left of a gap that a shorter rewrite opened before `gapTail`,
    /// the unchanged words after it: they glide left to close it.
    private var gap: CGFloat = 0
    private var gapTail = 0..<0
    /// How far the line has scrolled: the text coordinate at the wing's left
    /// edge. It never decreases for text that stays on screen.
    private var scroll: CGFloat = 0
    /// How long a rewrite of visible text waits for the provider to settle.
    /// Short enough for the pacer's reserve of new words to last through it.
    var rewriteHoldSeconds: TimeInterval = 0.35
    /// A rewrite that begins within this many of the newest visible characters
    /// is shown at once.
    static let unheldTailCharacters = 2
    private var heldRewrite: String?
    private var heldRewriteUntil: TimeInterval = 0
    var wingWidth: CGFloat = 0
    private var lastFrameAt: TimeInterval?
    /// How fast a slide is eased out (time constant).
    static let slideSeconds: TimeInterval = 0.12
    /// Unchanged text at the live edge at least this wide never moves when
    /// longer text is written before it.
    static let steadyTailWidth: CGFloat = 24
    private let font = NSFont.systemFont(ofSize: IslandLiveTextTickerModel.fontSize, weight: .medium)

    func prime(_ text: String, now: TimeInterval) {
        slide = 0
        gap = 0
        heldRewrite = nil
        ticker.prime(text, now: now)
        measure()
        scroll = 0
        followLiveEdge()
    }

    /// A provider may take visible words back and return them a moment later,
    /// or rewrite a chunk in several quick steps. A snapshot that changes text
    /// already on screen waits up to `rewriteHoldSeconds`; the newest one is
    /// then shown in one step. A snapshot that keeps the visible text (new
    /// words at the end, or a change of only its last two characters or its
    /// closing marks) is shown at once and cancels a waiting rewrite.
    /// The same for every provider: only the text is compared.
    /// WHY: .project-docs/decisions/2026-11-19-live-text-rewrite-hold.md
    func textArrived(_ text: String, now: TimeInterval) {
        let visible = ticker.characters.prefix(ticker.revealedCount)
        // The end of the visible text is often a provisional mark ("-" after
        // a word in progress, ".", "?", "...") that the next snapshot
        // replaces. Holding those made the line stand still. A change that
        // begins in the last two visible characters, or in marks and spaces
        // only, is shown at once.
        let kept = zip(visible, text).prefix { $0 == $1 }.count
        let changed = visible.dropFirst(kept)
        let provisional = changed.count <= Self.unheldTailCharacters ||
            changed.allSatisfy { $0.isPunctuation || $0.isWhitespace }
        if rewriteHoldSeconds <= 0 || provisional {
            heldRewrite = nil
            show(text, now: now)
        } else {
            if heldRewrite == nil { heldRewriteUntil = now + rewriteHoldSeconds }
            heldRewrite = text
        }
    }

    private func show(_ text: String, now: TimeInterval) {
        let oldCharacters = ticker.characters
        let oldShown = min(ticker.revealedCount, oldCharacters.count)
        let oldEdges = edges
        let oldWidth = revealedWidth
        ticker.textArrived(text, now: now)
        measure()
        guard wingWidth > 0, oldShown > 0 else {
            slide = 0
            gap = 0
            return
        }
        // A rewrite of visible text splits the line in two rigid pieces: the
        // text before the change and the unchanged text after it. Each piece
        // stays where it was on this frame and glides to its new place, so
        // nothing jumps and the spacing inside a piece never changes.
        // WHY: .project-docs/decisions/2026-11-15-live-text-rewrites.md
        let characters = ticker.characters
        let shown = min(ticker.revealedCount, characters.count)
        let shortest = min(oldShown, shown)
        var prefix = 0
        while prefix < shortest, oldCharacters[prefix] == characters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              oldCharacters[oldShown - 1 - suffix] == characters[shown - 1 - suffix] { suffix += 1 }
        // Change in width of everything before the unchanged tail.
        let delta = edges[shown - suffix] - oldEdges[oldShown - suffix]
        let tailVisible = min(wingWidth, max(0, oldWidth - oldEdges[oldShown - suffix]))
        // The scroll position only moves forward for text that stays on
        // screen. A provider that removes repeated words or a false start
        // makes the line shorter: the text before the change stays where it
        // is, the words after it close the gap, and the free space is left
        // at the right edge for new words. Scrolling back to press the end
        // against the edge moved the whole line backwards.
        // WHY: .project-docs/decisions/2026-11-21-live-text-forward-only.md
        // The tail is the piece that stays when the change began left of the
        // wing, or when longer text is written before words at the live edge
        // (the text before them makes room at once). Otherwise the start
        // stays: a short line, a shorter rewrite, or the live word itself.
        let tailStays = scroll > 0 &&
            (oldEdges[prefix] <= scroll || (delta > 0 && tailVisible >= Self.steadyTailWidth))
        let base = tailStays ? scroll + delta : scroll
        // A longer line that no longer fits glides forward to show its end.
        // A line cut so short that under a quarter of the wing would show
        // glides back that far: an almost empty wing reads as lost text.
        let width = revealedWidth
        let target = min(max(0, base, width - wingWidth), max(0, width - wingWidth / 4))
        let pushed = target - base
        scroll = target
        let limit = wingWidth / 2
        slide = min(limit, max(-limit, slide + pushed))
        if !tailStays, delta < 0, suffix > 0 {
            gap = min(wingWidth, -delta)
            gapTail = (shown - suffix)..<shown
        } else if prefix < gapTail.upperBound {
            // Another rewrite reached the words still closing an earlier gap.
            gap = 0
        }
    }

    var revealedGlyphCount: Int { min(ticker.revealedCount, ticker.characters.count) }

    /// The text the line currently draws from (a waiting rewrite is not in it).
    var shownText: String { String(ticker.characters) }

    private var scrollOffset: CGFloat { -scroll }

    /// Steady speech: the line scrolls on once its end reaches the right edge.
    private func followLiveEdge() {
        guard wingWidth > 0 else { return }
        scroll = max(scroll, revealedWidth - wingWidth)
    }

    /// A letter moves together with its whole piece of the line: the same
    /// amount for every letter in it (a per-letter amount stretched the text).
    func glyphX(at index: Int) -> CGFloat {
        edges[index] + scrollOffset + slide + (gapTail.contains(index) ? gap : 0)
    }

    private var revealedWidth: CGFloat {
        let count = min(ticker.revealedCount, ticker.characters.count)
        let fraction = CGFloat(ticker.revealed - Double(count))
        let nextWidth = count < ticker.characters.count ? edges[count + 1] - edges[count] : 0
        return edges[count] + fraction * nextWidth
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

    @discardableResult
    func advance(now: TimeInterval) -> CGFloat {
        if let rewrite = heldRewrite, now >= heldRewriteUntil {
            heldRewrite = nil
            show(rewrite, now: now)
        }
        let previous = lastFrameAt ?? now
        if lastFrameAt != nil, now <= previous { return revealedWidth }
        ticker.advance(now: now)
        lastFrameAt = now
        followLiveEdge()
        let decay = CGFloat(exp(-(now - previous) / Self.slideSeconds))
        slide = abs(slide * decay) < 0.05 ? 0 : slide * decay
        gap = abs(gap * decay) < 0.05 ? 0 : gap * decay
        return revealedWidth
    }

    func draw(in context: inout GraphicsContext, size: CGSize, now: TimeInterval, visibleWidth: CGFloat) {
        advance(now: now)
        if size.width != wingWidth {
            // A changed viewport keeps a line whose end was at the edge there.
            let atEdge = wingWidth > 0 && abs(scroll - (revealedWidth - wingWidth)) < 0.5
            wingWidth = size.width
            if atEdge { scroll = max(0, revealedWidth - wingWidth) }
        }
        followLiveEdge()
        let count = min(ticker.revealedCount, ticker.characters.count)
        guard count > 0 else { return }
        let offset = scrollOffset + slide
        let middle = size.height / 2

        var first = count - 1
        while first > 0, glyphX(at: first) > -24 { first -= 1 }

        context.drawLayer { layer in
            for index in first..<count {
                let character = ticker.characters[index]
                guard !character.isWhitespace else { continue }
                let progress = ticker.gatherProgress(at: index, now: now)
                let x = glyphX(at: index)
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
                        in: &layer, seed: ticker.bornAt[index].bitPattern ^ UInt64(character.unicodeScalars.first!.value), progress: progress,
                        origin: CGPoint(x: x, y: middle), width: edges[index + 1] - edges[index],
                        height: size.height, rightEdge: min(size.width, visibleWidth)
                    )
                }
            }
            guard offset < -0.5 else { return }
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
    /// The seed follows the revealed character through an earlier text insertion.
    private func drawGrains(
        in layer: inout GraphicsContext, seed: UInt64, progress: Double,
        origin: CGPoint, width: CGFloat, height: CGFloat, rightEdge: CGFloat
    ) {
        var random = GrainRandom(seed: seed)
        // Fit the spawn spread into the visible wing, so particles can gather
        // while it is still narrow, all the way up to its moving edge.
        let reach = min(86, max(0, rightEdge - origin.x))
        for _ in 0..<Self.grains {
            let home = CGPoint(x: origin.x + random.next() * width, y: origin.y + (random.next() - 0.5) * 8)
            let start = CGPoint(
                x: max(home.x, origin.x + reach * (16 + random.next() * 70) / 86),
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
