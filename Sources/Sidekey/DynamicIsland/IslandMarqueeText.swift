import SwiftUI

/// A single-line text label that scrolls horizontally ("marquee") ONLY
/// when its content is wider than the space it is given, and otherwise
/// renders statically. Built net-new for the Stage 3 player strip (the
/// island has cross-fade cyclers but no horizontal scroller).
///
/// Behaviour:
/// - Fits → static, `.lineLimit(1)`, no animation, no per-frame work.
/// - Overflows → the text is duplicated with a trailing gap and the pair
///   translates leftward via `TimelineView(.animation)`; the offset wraps
///   modulo (content + gap) so the loop is seamless.
/// - Reduce Motion → never scrolls; truncates with a tail ellipsis. This
///   is a hard accessibility requirement (no involuntary motion).
///
/// The overflow decision is a pure, testable function (`shouldScroll`).
/// Width measurement uses a `GeometryReader` overlay on a hidden static
/// copy so the loop length tracks the real rendered text width.
struct IslandMarqueeText: View {
    /// Rendered content. A plain `String` (uniform `font`/`color`) or an
    /// `AttributedString` carrying its own per-run styling (e.g. an
    /// emphasized title + a dimmer artist on one line). Both flow through
    /// the same measure / static / scroll paths so the overflow loop length
    /// always tracks the real rendered width.
    private let content: Content
    var font: Font = .system(size: 11, weight: .semibold)
    var color: Color = .white
    /// Points per second the content travels while scrolling.
    var speed: CGFloat = 30
    /// Empty space inserted between the end of the text and the start of
    /// its repeated copy, so the loop reads as a continuous strip.
    var gap: CGFloat = 32

    enum Content {
        case plain(String)
        case attributed(AttributedString)
    }

    /// Plain-text content styled uniformly by `font` / `color`.
    init(
        text: String,
        font: Font = .system(size: 11, weight: .semibold),
        color: Color = .white,
        speed: CGFloat = 30,
        gap: CGFloat = 32
    ) {
        self.content = .plain(text)
        self.font = font
        self.color = color
        self.speed = speed
        self.gap = gap
    }

    /// Attributed content carrying its own per-run styling. `font` / `color`
    /// act as the baseline the `AttributedString`'s runs override.
    init(
        attributed: AttributedString,
        font: Font = .system(size: 11, weight: .semibold),
        color: Color = .white,
        speed: CGFloat = 30,
        gap: CGFloat = 32
    ) {
        self.content = .attributed(attributed)
        self.font = font
        self.color = color
        self.speed = speed
        self.gap = gap
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Measured rendered width of one copy of the text. `0` until the
    /// hidden measuring copy reports back.
    @State private var contentWidth: CGFloat = 0

    /// Pure overflow predicate (Iron Law #1 seam). Content scrolls iff it
    /// is strictly wider than its envelope AND Reduce Motion is off. Equal
    /// widths are treated as "fits" — a title that exactly fills the
    /// envelope reads cleanly without motion.
    static func shouldScroll(
        contentWidth: CGFloat,
        envelopeWidth: CGFloat,
        reduceMotion: Bool
    ) -> Bool {
        guard !reduceMotion else { return false }
        guard envelopeWidth > 0, contentWidth > 0 else { return false }
        return contentWidth > envelopeWidth
    }

    var body: some View {
        GeometryReader { geometry in
            let envelope = geometry.size.width
            let scrolls = Self.shouldScroll(
                contentWidth: contentWidth,
                envelopeWidth: envelope,
                reduceMotion: reduceMotion
            )

            ZStack(alignment: .leading) {
                if scrolls {
                    scrollingContent
                } else {
                    staticContent
                }
            }
            .frame(width: envelope, height: geometry.size.height, alignment: .leading)
            .clipped()
        }
        .background(measuringOverlay)
    }

    // MARK: - Static (fits / Reduce Motion)

    private var staticContent: some View {
        label
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Scrolling (overflow, motion allowed)

    private var scrollingContent: some View {
        // One travel cycle covers one text copy plus the gap; the second
        // copy fills the void the first leaves so the strip never shows a
        // blank seam. `cycle` guards against a zero divisor before the
        // width measurement lands.
        let cycle = max(1, contentWidth + gap)
        return TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let distance = CGFloat(elapsed) * speed
            let offset = -distance.truncatingRemainder(dividingBy: cycle)

            HStack(spacing: gap) {
                label.fixedSize()
                label.fixedSize()
            }
            .offset(x: offset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Measurement

    /// A hidden, intrinsically-sized copy whose width is published into
    /// `contentWidth`. Drawn with zero opacity so it never paints but still
    /// lays out at the real text width.
    private var measuringOverlay: some View {
        label
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MarqueeContentWidthKey.self,
                        value: proxy.size.width
                    )
                }
            )
            .opacity(0)
            .accessibilityHidden(true)
            .onPreferenceChange(MarqueeContentWidthKey.self) { width in
                contentWidth = width
            }
    }

    @ViewBuilder
    private var label: some View {
        switch content {
        case .plain(let text):
            Text(text)
                .font(font)
                .foregroundStyle(color)
        case .attributed(let attributed):
            // The baseline `font` / `color` apply where the AttributedString
            // leaves a run unstyled; per-run attributes override them.
            Text(attributed)
                .font(font)
                .foregroundStyle(color)
        }
    }
}

/// Carries the measured intrinsic width of the marquee text up to the
/// container so it can decide whether to scroll and how long the loop is.
private struct MarqueeContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
