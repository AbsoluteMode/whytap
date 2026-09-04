import AppKit
import SwiftUI

/// Floating panel showing the hotkey hint table. Anchored above the orb
/// (Cocoa Y > orb.maxY) because the orb itself sits flush against the
/// bottom edge of the visible frame. Visibility is driven top-down by
/// `AppDelegate` via the "Hide Helpers" menu toggle
/// (`DisplayPreferences.hideHelpers`) — the panel itself no longer
/// hosts an inline hide affordance.
final class KeybindingsHintPanel: NSPanel {
    private static let panelWidth: CGFloat = KeybindingsHintView.panelWidth
    private static let panelHeight: CGFloat = KeybindingsHintView.panelHeight
    private static let marginBelowOrb: CGFloat = 4

    init() {
        let frame = Self.frameBelowOrb(
            visibleFrame: IslandScreenResolver.currentVisibleFrame()
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        // One level below `.statusBar` so any Sidekey overlay running at
        // `.statusBar` (orb, AgentTextInputPanel, AgentResponsePanel,
        // OrbActionsOverlayPanel) always reorders above the hint, while
        // the hint still beats the Dock (`kCGDockWindowLevelKey` ≈ 20)
        // and stays visible above other apps' regular windows + on
        // fullscreen Spaces. The previous `.floating - 1` (2) sat BELOW
        // the Dock and vanished on fullscreen Spaces.
        self.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.hidesOnDeactivate = false
        // Mouse events OFF — the panel no longer carries an inline
        // hide affordance, so clicks pass through to whatever sits
        // behind it (the chip is purely informational chrome).
        self.ignoresMouseEvents = true

        let host = NSHostingView(rootView: KeybindingsHintView())
        host.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = host

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: IslandScreenResolver.selectionDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showOnTop() {
        self.orderFrontRegardless()
    }

    @objc private func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setFrame(
                Self.frameBelowOrb(
                    visibleFrame: IslandScreenResolver.currentVisibleFrame()
                ),
                display: true
            )
        }
    }

    /// Centers the hint horizontally on the orb's vertical axis and
    /// places it just below the orb's bottom edge. After the dock-safe
    /// lift and the glow-padding bump the orb anchors at
    /// `visible.minY + 51` (11 base + 40 buffer; was 59pt before
    /// `glowMargin` rose 8 → 16 and `baseMarginBottom` dropped 19 →
    /// 11 to preserve the orb's visual centre), so the hint lands at
    /// `visible.minY + 51 - 4 - panelHeight`. With the compact-chip
    /// envelope (`panelHeight = compactChipIntrinsicHeight`) the hint
    /// sits at `visible.minY + 51 - 4 - 18 = visible.minY + 29` — still
    /// clear of the Dock (`kCGDockWindowLevelKey` ≈ 20pt physical
    /// height at small/medium sizes; magnified Dock is still covered
    /// by the `.statusBar - 1` window level).
    ///
    /// Pure logic (no `NSScreen`) — callers pass
    /// `IslandScreenResolver.currentVisibleFrame()`; tests pass fixtures.
    static func frameBelowOrb(visibleFrame visible: NSRect) -> NSRect {
        let orb = FloatingDotPanel.bottomRightFrame(visibleFrame: visible, expanded: false)
        let originX = orb.midX - panelWidth / 2
        let originY = orb.minY - marginBelowOrb - panelHeight
        return NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight)
    }
}
