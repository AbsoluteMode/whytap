import AppKit

/// Lightweight bundled-PDF loader + per-process cache for the
/// hover-panel control orbs (`IslandHoverPanelControl` in PDF mode).
///
/// Mirrors the pipeline `OrbActionIcon` uses for the orb-mini-trigger
/// PDFs but takes an arbitrary resource name so we can add new tiles
/// (Drop Mode fast/smart, Language, …) without
/// extending a fixed enum each time. The PDFs themselves are converted
/// from `svg v2/*.svg` via `rsvg-convert -f pdf` and copied into the
/// bundle by `scripts/dev-run.sh` / `scripts/build-dmg.sh`.
///
/// `isTemplate` stays `false` so AppKit does NOT discard the PDF's
/// embedded palette (Maxim's orbs carry their own colour identity —
/// pink/violet for Agent-tinted glyphs, white for Drop, etc.). The
/// shared `NSImage` per resource is held for the lifetime of the
/// process; `NSImage` caches the rasterised CGImage internally, so
/// repeated draws don't re-parse the PDF.
@MainActor
enum IslandControlIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(named resourceName: String) -> NSImage? {
        if let cached = cache[resourceName] {
            return cached
        }
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "pdf"
        ) else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        if let image {
            image.cacheMode = .never
            cache[resourceName] = image
        }
        return image
    }
}
