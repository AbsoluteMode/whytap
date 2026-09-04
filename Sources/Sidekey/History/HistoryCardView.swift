import AppKit
import SwiftUI

/// One card rendered inside the bottom strip. Renders different content
/// depending on the card's underlying entry kind:
///  * Agent → title (or fallback) + truncated response body + link chips
///  * Drop → formatted text + target app caption
///  * Clipboard text → text body
///  * Clipboard image → thumbnail preview
///  * Clipboard files → first filename + count caption
///
/// Hover behaviour: subtle scale + brightness lift. Click body → copy
/// to system pasteboard via `onCopy`. Top-right expand button → opens
/// the centered expanded view via `onExpand`.
struct HistoryCardView: View {
    let card: HistoryStripCard
    /// Per-card width. ROO-208 iter 3: the iter-2 fixed 260pt width was
    /// parameterized so the new horizontal-row layout can compute a
    /// rubbery width to fit exactly 5 cards across the cards-area.
    /// Default = `cardWidth` (legacy 260pt) — preserves call sites in
    /// tests and other consumers that don't care about the new layout.
    let width: CGFloat
    let assetsDirectory: URL
    let onCopy: () -> Void
    let onExpand: () -> Void
    /// ROO-208 iter 15: hover transition reported up to the strip
    /// controller. `true` on enter, `false` on exit. Drives both the
    /// "Paste to <App> ↵" hint and the Enter-key paste flow's card
    /// selection. Default = no-op so tests / preview call sites that
    /// don't care about hover stay unchanged.
    let onHoverChange: (Bool) -> Void

    init(
        card: HistoryStripCard,
        width: CGFloat = HistoryCardView.cardWidth,
        assetsDirectory: URL,
        onCopy: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onHoverChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.card = card
        self.width = width
        self.assetsDirectory = assetsDirectory
        self.onCopy = onCopy
        self.onExpand = onExpand
        self.onHoverChange = onHoverChange
    }

    /// Card sizing — picked so 3–5 cards fit horizontally on a 1440-wide
    /// screen, leaving the strip room for the close button and bottom
    /// margin. Card body uses `DarkGlassCard` with these dimensions.
    /// `cardWidth` remains the legacy default; the row layout overrides
    /// it via the `width` init parameter so cards fit the available
    /// cards-area width. Card height was 180pt; post-shrink 126pt
    /// (180 × 0.7) so cards stay proportional to the slimmer strip
    /// frame (`HistoryStripPanel.height` 220pt → 154pt). Text
    /// `lineLimit`s (5 / 6 / 7) still fit because the per-line height
    /// (≈14pt at 11pt font) leaves room for the truncated body lines.
    static let cardWidth: CGFloat = 260
    static let cardHeight: CGFloat = 126
    static let cardCornerRadius: CGFloat = 18

    @State private var isHovered: Bool = false

    var body: some View {
        DarkGlassCard(
            width: width,
            height: Self.cardHeight,
            cornerRadius: Self.cardCornerRadius
        ) {
            cardBody
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .brightness(isHovered ? 0.05 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { hovered in
            isHovered = hovered
            if hovered { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
            onHoverChange(hovered)
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        ZStack(alignment: .topTrailing) {
            // Body: click copies. `Button` wrapping makes it
            // keyboard-accessible.
            Button(action: onCopy) {
                contentForCard
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(
                        width: width,
                        height: Self.cardHeight,
                        alignment: .topLeading
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expand button — top-right inside an SF Symbol circle.
            // Round 2 UX 8: hover lifts the circle's tint, press
            // bounces the icon up to 1.15× with a snappy spring.
            ExpandIconButton(action: onExpand)
                .padding(8)
                .accessibilityLabel("Expand")
        }
    }

    @ViewBuilder
    private var contentForCard: some View {
        switch card {
        case .agent(let c):
            agentBody(c)
        case .drop(let c):
            dropBody(c)
        case .clipboard(let c):
            clipboardBody(c)
        }
    }

    // MARK: - Agent

    @ViewBuilder
    private func agentBody(_ c: HistoryStripCard.AgentCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.title ?? "Agent response")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            MarkdownText(raw: c.responseMarkdown.isEmpty ? "(empty)" : c.responseMarkdown)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
            if !c.links.isEmpty {
                linkChipsRow(c.links)
            }
            Spacer(minLength: 0)
            timestampLine(c.createdAt)
        }
    }

    private func linkChipsRow(_ links: [URL]) -> some View {
        HStack(spacing: 4) {
            ForEach(links.prefix(3), id: \.self) { url in
                Text(url.host ?? url.absoluteString)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .lineLimit(1)
            }
            if links.count > 3 {
                Text("+\(links.count - 3)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: - Drop

    @ViewBuilder
    private func dropBody(_ c: HistoryStripCard.DropCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drop")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(c.formattedText.isEmpty ? "(empty)" : c.formattedText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack {
                if let app = c.targetApp {
                    Text(app)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                timestampLine(c.createdAt)
            }
        }
    }

    // MARK: - Clipboard

    @ViewBuilder
    private func clipboardBody(_ c: HistoryStripCard.ClipboardCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch c.payload {
            case .text(let s):
                Text("Text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(s)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(7)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                timestampLine(c.createdAt)

            case .image(let img):
                Text("Image")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if let nsImage = NSImage(data: img.thumbnailData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    placeholderImage
                }
                Spacer(minLength: 0)
                timestampLine(c.createdAt)

            case .fileURLs(let urls):
                Text("Files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                ForEach(urls.prefix(3), id: \.self) { url in
                    Text(url.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if urls.count > 3 {
                    Text("+\(urls.count - 3) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                timestampLine(c.createdAt)
            }
        }
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .frame(height: 110)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.4))
            )
    }

    // MARK: - Helpers

    private func timestampLine(_ date: Date) -> some View {
        Text(Self.relativeTimestamp(for: date))
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.45))
    }

    static func relativeTimestamp(for date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Card-corner expand button with hover-tint + press-bounce. The
/// hover state changes the background circle's tint from the resting
/// `.white.opacity(0.12)` to a brighter `.white.opacity(0.28)` and
/// the icon's foreground from `.white.opacity(0.85)` to white. The
/// press state animates a 1.0 → 1.15 → 1.0 scale via the custom
/// `BouncyButtonStyle`.
///
/// Factored into its own view so `HistoryCardView.cardBody` stays
/// readable; rendered identically for every card variant.
struct ExpandIconButton: View {
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.white : .white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        Color.white.opacity(isHovered ? 0.28 : 0.12)
                    )
                )
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(BouncyButtonStyle())
        .onHover { hovered in
            isHovered = hovered
            // Don't reset the cursor here — the parent card's `.onHover`
            // sets `.pointingHand` over the whole card surface; the
            // expand button is inside that area so the cursor stays
            // pointing-hand throughout.
        }
    }
}

/// Press-bounce ButtonStyle: scales the label up to ~1.15× while
/// pressed, springs back to 1.0× on release. Used by the expand
/// button per Maxim's Round 2 UX 8 spec — classic Apple iOS button
/// feedback.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.15 : 1.0)
            .animation(
                .spring(response: 0.20, dampingFraction: 0.5),
                value: configuration.isPressed
            )
    }
}
