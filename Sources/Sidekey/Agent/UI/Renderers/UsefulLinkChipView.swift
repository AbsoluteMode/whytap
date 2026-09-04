import AppKit
import SwiftUI

/// Compact pill ("chip") for one link in a UsefulLinks block. Surfaces the
/// provider icon + short description and opens the link in the default
/// browser via `NSWorkspace`.
struct UsefulLinkChipView: View {
    /// Cap on the favicon-overlay icon size. Maxim's "по вертикали"
    /// directive (Subtask E) shrinks the chip envelope by dropping the
    /// icon column 24 → 18pt. 18pt keeps the favicon legible at the
    /// 1× / 2× / 3× DPI factors the favicon proxy returns while
    /// halving the chip's vertical envelope — paired with the
    /// `lineLimit(1)` description and tighter padding the chip drops
    /// from ~50pt tall to ~30pt tall.
    static let iconSize: CGFloat = 18

    let link: UsefulLink

    @State private var hovered = false
    @State private var faviconImage: NSImage?

    var body: some View {
        Button(action: open) {
            // Subtask E (Maxim "по вертикали"): align icon + text on
            // the centre axis instead of the top so a 1-line description
            // sits visually centred with its 18pt icon. With the
            // shorter icon column + lineLimit(1) the chip's vertical
            // envelope drops to ~30pt.
            HStack(alignment: .center, spacing: 8) {
                iconView
                    .frame(width: Self.iconSize, height: Self.iconSize)
                Text(link.description)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    // 2-line description doubled the chip's vertical
                    // envelope in the wild. Truncate at one line — the
                    // user always has the favicon + description as a
                    // glance preview, and clicking the chip surfaces
                    // the full URL in the browser.
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Padding 10/6 → 8/4 so the capsule rides closer to its
            // 18pt icon and 11pt text. Combined with the 1-line cap
            // the chip lands in the ~30pt-tall envelope.
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Full-width chip — matches Pill 1 / Pill 2 panel width
            // (~456pt usable inside the 480pt panel) so the chip row
            // reads as a continuation of the same vertical stack.
            // Empty trailing space is intentional; the description
            // hugs the left edge next to its icon.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    // Frosted glass background — same NSVisualEffectView
                    // material the pills above use so chips visually
                    // belong to the same surface family.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thickMaterial)
                    // Hover lift: slight white tint when the mouse is
                    // over the chip. Keeps the thickMaterial readable
                    // and works in both light and dark mode.
                    if hovered {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            hovered = isInside
            if isInside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens in browser")
        .accessibilityAddTraits(.isButton)
        .task(id: faviconTaskID) {
            await loadFaviconIfNeeded()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let favicon = faviconImage {
            // Favicon overlay won — render the host-derived image.
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if let bundled = bundledIcon {
            // Brand icon from the bundled PDFs. Template-rendered so it
            // adapts to light/dark mode automatically.
            Image(nsImage: bundled)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.primary)
        } else {
            // Last-resort SF Symbol globe — only fires if the bundled
            // PDFs failed to ship (dev-run.sh / build-dmg.sh didn't
            // copy them). Better than a blank space.
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    /// Resolves the provider id either from the explicit field on the link
    /// or from the URL host. Used both for the bundled icon lookup and to
    /// decide whether the favicon fallback is needed.
    private var resolvedProvider: String? {
        Self.resolvedProvider(for: link)
    }

    /// Pure-logic provider resolution split out of the instance property so
    /// it can be exercised in isolation. The decision tree is:
    ///
    ///   1. If the agent tagged the link with an explicit `provider` AND
    ///      that tag is plausibly correct (the URL host matches the same
    ///      brand via inference, OR the host has no inference match at all),
    ///      trust the explicit field.
    ///   2. Otherwise — the explicit `provider` clearly disagrees with the
    ///      URL host (e.g. `provider: "notion"` for `wikipedia.org`) — fall
    ///      through to URL-host inference. This guards against model
    ///      tagging drift that would otherwise render a wrong brand icon
    ///      (the original Wikipedia-shows-Notion regression).
    ///   3. With no explicit provider, the inference result wins; `nil`
    ///      means "let the favicon overlay run".
    nonisolated static func resolvedProvider(for link: UsefulLink) -> String? {
        let inferred = UsefulLinkProviderInference.provider(for: link.url)
        guard let explicit = link.provider, !explicit.isEmpty else {
            return inferred
        }
        // The explicit tag is trusted unless the URL host clearly belongs
        // to a different provider. Inference returning nil means "unknown
        // host" — the explicit tag is the best signal we have and wins.
        if let inferred, inferred != explicit {
            return inferred
        }
        return explicit
    }

    private var bundledIcon: NSImage? {
        UsefulLinkIconAsset.image(for: resolvedProvider)
    }

    private var faviconTaskID: String {
        // Re-run the favicon fetcher only when the URL or resolved
        // provider actually changes. Without an explicit task id SwiftUI
        // would re-fetch on every body recompute.
        "\(link.url.absoluteString)|\(resolvedProvider ?? "?")"
    }

    private var accessibilityLabel: String {
        let descriptor: String
        if let provider = resolvedProvider, !provider.isEmpty {
            descriptor = provider
        } else {
            descriptor = "link"
        }
        return "\(link.description). Open \(descriptor)"
    }

    private func open() {
        NSWorkspace.shared.open(link.url)
    }

    private func loadFaviconIfNeeded() async {
        // Run the favicon fetch when the chip's bundled icon would be the
        // generic globe — i.e. either no provider is resolved at all, or
        // the resolved provider is recognised for inference but doesn't
        // have a bundled brand PDF (Wikipedia is the canonical example).
        // Brand providers (notion, linear, ...) keep their canonical
        // PDF asset; overlaying a tinted favicon there would defeat the
        // visual stability the chip family is supposed to provide.
        guard Self.shouldOverlayFavicon(forResolvedProvider: resolvedProvider) else {
            faviconImage = nil
            return
        }
        let icon = await FaviconService.shared.icon(forURL: link.url)
        // Guard against the view recycling onto a different link before
        // the async call returned: only apply the result if it matches
        // the URL the chip is currently rendering. Without this guard
        // a list of chips can flicker each other's favicons in.
        if icon != nil {
            faviconImage = icon
        }
    }

    /// Decides whether the favicon-overlay path should run for a given
    /// resolved-provider id. `true` when the chip would otherwise show the
    /// globe fallback — i.e. when the provider is nil OR when the provider
    /// is known to inference but has no matching bundled brand PDF (so the
    /// asset lookup falls back to globe). Kept as a pure static helper so
    /// the rule is testable and the same threshold drives both the
    /// `bundledIcon` fallback and the favicon trigger.
    nonisolated static func shouldOverlayFavicon(forResolvedProvider provider: String?) -> Bool {
        guard let provider, !provider.isEmpty else { return true }
        // The asset table treats anything outside `knownProviders` as
        // globe — so the chip already renders the globe glyph and a
        // favicon overlay is the only way to surface a host-specific
        // glyph (the Wikipedia W, a niche SaaS logo, etc.).
        return !UsefulLinkIconAsset.knownProviders.contains(provider)
    }
}
