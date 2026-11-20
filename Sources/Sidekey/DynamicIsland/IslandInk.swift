import AppKit
import SwiftUI

/// The foreground of island panels that Settings -> Toolbox also embeds
/// (Vocab, Filler, Case, the language pickers, Notify, History, Monitor).
/// In the island, whose window is always dark, it is white exactly as before;
/// in Settings it follows the window's light or dark appearance, so an
/// embedded panel sits on the same background as every other tool pane.
// WHY: .project-docs/decisions/2026-11-20-toolbox-system-background.md
enum IslandInk {
    static let ns = NSColor(name: NSColor.Name("Whytap.Island.ink")) { appearance in
        isDark(appearance)
            ? .white
            : NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    }
    static let color = Color(nsColor: ns)

    /// An opaque row surface: the island's dark row, a light grey row on
    /// light Settings.
    static let row = Color(nsColor: NSColor(name: NSColor.Name("Whytap.Island.row")) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xF0 / 255, alpha: 1)
    })

    /// A darkening plate behind content (History rows and hints, the Notify
    /// section switch). In the island it is black at `darkOpacity`, as
    /// before; on light Settings it is a faint tint, a little stronger for a
    /// stronger plate, so the dark ink on it stays readable.
    static func plate(_ darkOpacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDark(appearance)
                ? NSColor.black.withAlphaComponent(darkOpacity)
                : NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255,
                          alpha: 0.05 + 0.06 * min(1, max(0, darkOpacity)))
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
