import AppKit
import SwiftUI

// WHY: .project-docs/decisions/2026-11-21-calendar-logos.md
/// Logos of the calendar services for events and the Connect list: the
/// official Google Calendar and Outlook icons, Zoom and Whytap from the bundle,
/// and the installed Calendar app's icon for Calendar on this Mac. Transparent
/// margins are trimmed so every logo fills the same square. Nothing is downloaded.
@MainActor
enum CalendarSourceLogo {
    static let appleCalendarBundleID = "com.apple.iCal"

    /// Tests point this at the repository's Resources/UsefulLinkIcons.
    static var resourceDirectoryForTesting: URL? { didSet { cache.removeAll() } }
    /// Tests replace the installed-app lookup.
    static var applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } {
        didSet { cache.removeAll() }
    }

    static func image(for source: CalendarEventSource) -> NSImage? {
        if let cached = cache[source] { return cached }
        let image = make(source).map(trimmed)
        if let image { cache[source] = image }
        return image
    }

    private static func make(_ source: CalendarEventSource) -> NSImage? {
        switch source {
        case .whytap: return bundled("whytap")
        case .provider(.google): return bundled("google-calendar")
        case .provider(.microsoft): return bundled("outlook")
        case .provider(.zoom): return bundled("zoom")
        case .provider(.apple):
            guard let url = applicationURL(appleCalendarBundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    private static func bundled(_ name: String) -> NSImage? {
        let url: URL?
        if let resourceDirectoryForTesting {
            url = resourceDirectoryForTesting.appendingPathComponent("\(name).png")
        } else {
            url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "UsefulLinkIcons")
                ?? Bundle.main.url(forResource: name, withExtension: "png")
        }
        guard let url, FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }

    /// App icons carry a transparent margin and flat logos do not; cropping to the
    /// visible pixels makes them the same size side by side.
    static func trimmed(_ image: NSImage) -> NSImage {
        let side = 128
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: side * 4, bitsPerPixel: 32) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { return image }
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where data[(y * side + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, maxX - minX < side - 2 || maxY - minY < side - 2 else { return image }
        // Bitmap rows run top-down; drawing rects run bottom-up.
        let size = image.size, scale = size.width / CGFloat(side)
        let crop = NSRect(x: CGFloat(minX) * scale, y: CGFloat(side - 1 - maxY) * scale,
                          width: CGFloat(maxX - minX + 1) * scale, height: CGFloat(maxY - minY + 1) * scale)
        let edge = max(crop.width, crop.height)
        let square = NSRect(x: crop.midX - edge / 2, y: crop.midY - edge / 2, width: edge, height: edge)
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            image.draw(in: rect, from: square, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private static var cache: [CalendarEventSource: NSImage] = [:]
}

/// An event's or a provider's logo; an unknown calendar gets a calendar symbol.
struct CalendarSourceLogoView: View {
    let source: CalendarEventSource?
    let size: CGFloat

    var body: some View {
        Group {
            if let source, let image = CalendarSourceLogo.image(for: source) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "calendar").font(.system(size: size * 0.78, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
