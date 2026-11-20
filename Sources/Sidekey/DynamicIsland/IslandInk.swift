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
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .white
            : NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    }
    static let color = Color(nsColor: ns)
}
