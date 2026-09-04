import AppKit
import SwiftUI

/// Native macOS frosted-glass backing (behind-window vibrancy) for the
/// Dynamic Island's detached surfaces — the hover panel (pre-Tahoe
/// fallback), the notification pill and the Aurora window chrome. Uses
/// `NSVisualEffectView` so the blur matches Control Center / the Agent
/// panel rather than SwiftUI's flatter `.ultraThinMaterial`.
///
/// `.popover` matches the material Apple uses for Control Center widgets —
/// lighter and more translucent than `.hudWindow`, giving the liquid-glass look.
struct IslandVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    static func makeBackingView(
        material: NSVisualEffectView.Material
    ) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        // Pinned dark: the product is dark-only, so the material must not
        // follow the user's system appearance — in light mode the unpinned
        // material rendered near-white and made the island look completely
        // different across machines. The wallpaper still bleeds through the
        // behind-window blur; only the material's tone is fixed.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.makeBackingView(material: material)
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
