import AppKit
import SwiftUI

// WHY: .project-docs/decisions/2026-11-21-calendar-logos.md
/// Small logos of the calendar services for events and the Connect list.
/// Bundled marks for Google Calendar, Zoom and Whytap; the installed app's
/// icon for Calendar on this Mac and for Outlook. Nothing is downloaded.
@MainActor
enum CalendarSourceLogo {
    static let appleCalendarBundleID = "com.apple.iCal"
    static let outlookBundleID = "com.microsoft.Outlook"
    /// Google's blue on a white tile, as the Google Calendar app icon is drawn.
    static let googleBlue = NSColor(srgbRed: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255, alpha: 1)
    /// Outlook's blue for the tile shown when Outlook is not installed.
    static let outlookBlue = NSColor(srgbRed: 0, green: 0x78 / 255, blue: 0xD4 / 255, alpha: 1)

    /// Tests point this at the repository's Resources/UsefulLinkIcons.
    static var resourceDirectoryForTesting: URL? { didSet { cache.removeAll() } }
    /// Tests replace the installed-app lookup.
    static var applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } {
        didSet { cache.removeAll() }
    }

    static func image(for source: CalendarEventSource) -> NSImage? {
        if let cached = cache[source] { return cached }
        let image = make(source)
        if let image { cache[source] = image }
        return image
    }

    private static func make(_ source: CalendarEventSource) -> NSImage? {
        switch source {
        case .whytap: return bundled("whytap", ext: "png")
        case .provider(.zoom): return bundled("zoom", ext: "png")
        case .provider(.google):
            return bundled("gcalendar", ext: "pdf").map { tile(mark: $0, background: .white, tint: googleBlue) }
        case .provider(.apple): return appIcon(appleCalendarBundleID)
        case .provider(.microsoft):
            return appIcon(outlookBundleID) ?? NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
                .map { tile(mark: $0, background: outlookBlue, tint: .white) }
        }
    }

    private static func bundled(_ name: String, ext: String) -> NSImage? {
        let url: URL?
        if let resourceDirectoryForTesting {
            url = resourceDirectoryForTesting.appendingPathComponent("\(name).\(ext)")
        } else {
            url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "UsefulLinkIcons")
                ?? Bundle.main.url(forResource: name, withExtension: ext)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = applicationURL(bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// A monochrome mark on a rounded tile, the size of an app icon's body.
    private static func tile(mark: NSImage, background: NSColor, tint: NSColor) -> NSImage {
        let tinted = NSImage(size: mark.size, flipped: false) { rect in
            mark.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let body = rect.insetBy(dx: 6, dy: 6)
            background.setFill()
            NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12).fill()
            let side = body.width * 0.62
            tinted.draw(in: NSRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side))
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
