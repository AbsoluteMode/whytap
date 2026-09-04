import AppKit
import Foundation

/// Resolves a Useful Links chip's brand icon. Two layers:
///   1. **Bundled provider PDFs** keyed by the canonical lowercase provider
///      string (`notion`, `linear`, `slack`, ...). Loaded from the
///      `UsefulLinkIcons/` subdirectory of the app bundle.
///   2. **Globe fallback** PDF, also bundled, for unknown / nil providers.
///
/// Bound to the bundle synchronously so the chip never has to fetch from
/// the network before showing *something*. The async favicon service (see
/// `FaviconService`) is a parallel concern that overlays a host-derived
/// icon on top once it resolves.
enum UsefulLinkIconAsset {
    /// Lowercase provider ids a `useful_links` block may carry. Listed here as a static
    /// table so unit tests can sweep all of them and so the chip view can
    /// branch on canonical inputs only. Anything outside this set is treated
    /// as unknown and falls through to globe + favicon overlay.
    static let knownProviders: Set<String> = [
        "notion",
        "linear",
        "slack",
        "github",
        "gmail",
        "gcalendar",
        "jira",
        "figma",
        "asana",
        "confluence",
        "discord",
        "trello"
    ]

    /// Globe fallback asset name. Bundled the same way as the brand icons.
    static let fallbackAssetName: String = "globe"

    /// Returns the bundle asset name to load for `provider`.
    /// `nil` / unknown → globe fallback.
    static func assetName(for provider: String?) -> String {
        guard let raw = provider else { return fallbackAssetName }
        let canonical = raw.lowercased()
        return knownProviders.contains(canonical) ? canonical : fallbackAssetName
    }

    /// Loads the bundled PDF for `assetName` once and caches the result
    /// for the lifetime of the process. NSImage holds a CGImage cache
    /// internally so repeated draws don't re-parse the PDF.
    static func image(named assetName: String) -> NSImage? {
        if let cached = cache[assetName] {
            return cached
        }
        guard let url = Bundle.main.url(
            forResource: assetName,
            withExtension: "pdf",
            subdirectory: "UsefulLinkIcons"
        ) ?? Bundle.main.url(
            // Some packaging variants flatten the subdirectory — fall back
            // to a flat lookup before giving up so a future Asset Catalog
            // migration doesn't break the chip silently.
            forResource: assetName,
            withExtension: "pdf"
        ) else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        if let image {
            cache[assetName] = image
        }
        return image
    }

    /// Convenience: bundle image for a given provider id (or globe).
    static func image(for provider: String?) -> NSImage? {
        image(named: assetName(for: provider))
    }

    private static var cache: [String: NSImage] = [:]
}

/// Heuristic provider detection from a URL host. Used when the agent
/// emits a link without a `provider` field — pick the bundled icon if
/// the host looks like one of our known providers, otherwise fall back
/// to the globe (which the favicon service may then overlay).
enum UsefulLinkProviderInference {
    /// Map host substring → canonical provider id. Substring match (not
    /// exact equality) so `mail.google.com` resolves to gmail and
    /// `app.asana.com` to asana without hardcoding every subdomain.
    ///
    /// Ordering matters: more-specific patterns must precede the less-
    /// specific ones they overlap with. The Jira/Confluence pair both
    /// live on `*.atlassian.net`, so the Confluence `/wiki/` path match
    /// must come BEFORE the bare `atlassian.net` host match.
    private static let hostMatchers: [(needle: String, provider: String)] = [
        ("notion.so", "notion"),
        ("notion.site", "notion"),
        ("linear.app", "linear"),
        ("slack.com", "slack"),
        ("github.com", "github"),
        ("mail.google.com", "gmail"),
        ("calendar.google.com", "gcalendar"),
        ("atlassian.net/wiki", "confluence"),
        ("confluence.com", "confluence"),
        ("atlassian.net", "jira"),
        ("jira.com", "jira"),
        ("figma.com", "figma"),
        ("asana.com", "asana"),
        ("discord.com", "discord"),
        ("discord.gg", "discord"),
        ("trello.com", "trello"),
        // Wikipedia: the inference returns the canonical "wikipedia" id even
        // though we don't ship a `wikipedia.pdf` brand asset. The chip's
        // bundled-icon lookup falls back to globe for unknown ids (see
        // `UsefulLinkIconAsset.assetName(for:)`) and the favicon path then
        // overlays Wikipedia's W glyph via Google S2. Substring matching on
        // `wikipedia.org` covers every language subdomain (en, ru, de, ja,
        // ...) without enumerating them — and, more importantly, it lets the
        // chip's resolution defend against a model that mistakenly tags a
        // wiki link with `provider: "notion"` (or any other brand).
        ("wikipedia.org", "wikipedia")
    ]

    /// Returns a canonical provider id if `url`'s host (and path for the
    /// Jira/Confluence shared atlassian.net domain) matches a known
    /// pattern. `nil` means "use the favicon fallback".
    static func provider(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let target = host + (url.path.lowercased())
        for matcher in hostMatchers where target.contains(matcher.needle) {
            return matcher.provider
        }
        return nil
    }
}
