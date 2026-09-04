import AppKit
import SwiftUI

/// Pure decisions for the History hover preview bubble: when a row needs
/// one, and how large an image renders. Kept UI-free so it is unit-testable.
enum HistoryHoverPreviewPolicy {
    static let bubbleWidth: CGFloat = 280
    static let bubbleMaxContentHeight: CGFloat = 360
    static let contentPadding: CGFloat = 8
    /// Font of the row's one-line label — used to measure whether the text
    /// actually fits the row's text slot.
    static let rowTextFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    /// Preview text: surrounding whitespace/newlines stripped so the bubble
    /// hugs the actual content — clipboard text often carries trailing
    /// newlines that would otherwise inflate the bubble with empty space.
    static func previewText(for card: HistoryStripCard) -> String {
        HistoryHoverContent.displayText(for: card)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func needsPreview(for card: HistoryStripCard, availableTextWidth: CGFloat) -> Bool {
        if case .clipboard(let c) = card {
            switch c.payload {
            case .image, .fileURLs: return true
            case .text: break
            }
        }
        let text = previewText(for: card)
        if text.contains(where: \.isNewline) { return true }
        let width = (text as NSString).size(withAttributes: [.font: rowTextFont]).width
        return width > availableTextWidth
    }

    /// «Optimal» image size: natural when it fits the cap, aspect-fit
    /// downscale otherwise — never upscaled.
    static func imageDisplaySize(natural: CGSize, cap: CGSize) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let scale = min(1, min(cap.width / natural.width, cap.height / natural.height))
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    /// `true` when `text` laid out at `width` exceeds the bubble's max
    /// content height — the bubble then applies a bottom fade-out mask.
    static func textOverflowsVertically(_ text: String, width: CGFloat) -> Bool {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        return bounds.height > bubbleMaxContentHeight
    }

    /// Full-size image for the bubble — same sidecar-then-thumbnail
    /// resolution as `HistoryExpandedView`.
    static func previewImage(
        for payload: ClipboardImagePayload,
        assetsDirectory: URL?
    ) -> NSImage? {
        if let assetsDirectory,
           let data = try? Data(contentsOf: payload.sidecarURL(in: assetsDirectory)),
           let image = NSImage(data: data) {
            return image
        }
        return NSImage(data: payload.thumbnailData)
    }
}

struct HistoryHoverPreviewAnchor: Equatable {
    let card: HistoryStripCard
    /// Hovered row frame in the island hover-zone coordinate space.
    let rowFrame: CGRect
}

/// Non-interactive dark bubble shown to the LEFT of the hover panel while a
/// row with overflowing / visual content is hovered.
struct HistoryHoverPreviewBubble: View {
    let card: HistoryStripCard
    /// Root of the clipboard image sidecar store; `nil` falls back to the
    /// 64×64 thumbnail bytes embedded in the payload.
    let assetsDirectory: URL?

    var body: some View {
        content
            .padding(HistoryHoverPreviewPolicy.contentPadding)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.black.opacity(0.46))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case .agent, .drop:
            textBody(HistoryHoverPreviewPolicy.previewText(for: card))
        case .clipboard(let c):
            switch c.payload {
            case .text: textBody(HistoryHoverPreviewPolicy.previewText(for: card))
            case .image(let image): imageBody(image)
            case .fileURLs(let urls): filesBody(urls)
            }
        }
    }

    @ViewBuilder
    private func textBody(_ text: String) -> some View {
        let width = HistoryHoverPreviewPolicy.bubbleWidth
            - HistoryHoverPreviewPolicy.contentPadding * 2
        let base = Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.88))
        // NB: no `.frame(maxHeight:)` here — with a tall parent proposal that
        // modifier GROWS the view to the cap (greedy, like `maxWidth:
        // .infinity`), inflating short previews with empty space. Short text
        // hugs its content; only overflowing text gets the fixed-height
        // clip + bottom fade.
        if HistoryHoverPreviewPolicy.textOverflowsVertically(text, width: width) {
            base
                .frame(
                    width: width,
                    height: HistoryHoverPreviewPolicy.bubbleMaxContentHeight,
                    alignment: .topLeading
                )
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        } else {
            base
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func imageBody(_ payload: ClipboardImagePayload) -> some View {
        if let image = HistoryHoverPreviewPolicy.previewImage(
            for: payload, assetsDirectory: assetsDirectory
        ) {
            let cap = CGSize(
                width: HistoryHoverPreviewPolicy.bubbleWidth
                    - HistoryHoverPreviewPolicy.contentPadding * 2,
                height: HistoryHoverPreviewPolicy.bubbleMaxContentHeight
            )
            let size = HistoryHoverPreviewPolicy.imageDisplaySize(natural: image.size, cap: cap)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Text("Image unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func filesBody(_ urls: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(urls, id: \.self) { url in
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(
            width: HistoryHoverPreviewPolicy.bubbleWidth
                - HistoryHoverPreviewPolicy.contentPadding * 2,
            alignment: .topLeading
        )
    }
}
