import AppKit

enum SidekeyWindowChrome {
    struct ScreenCandidate {
        let frame: NSRect
        let visibleFrame: NSRect
    }

    @MainActor
    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        // Keep the Settings shell frameless; any AppKit shadow follows the
        // transparent content rect and reads as an extra outer border.
        window.hasShadow = false
        window.invalidateShadow()
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }

    @MainActor
    static func configureHoverOverlayPolicy(_ window: NSWindow) {
        // Windows opened from the hover island are part of the app's
        // overlay surface, not normal document windows. Match the
        // clipboard/history layer so they stay visible from another
        // app's full-screen Space, while onboarding deliberately opts out.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    @MainActor
    static func centerOnMainScreen(_ window: NSWindow) {
        guard let visibleFrame = preferredVisibleFrame(for: window) else { return }
        center(window, inVisibleFrame: visibleFrame)
    }

    @MainActor
    static func centerOnMainScreenAfterNextLayout(_ window: NSWindow) {
        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window else { return }
            centerOnMainScreen(window)
        }
    }

    @MainActor
    static func preferredVisibleFrame(for window: NSWindow) -> NSRect? {
        let candidates = NSScreen.screens.map {
            ScreenCandidate(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        return primaryVisibleFrame(candidates: candidates)
            ?? NSScreen.main?.visibleFrame
            ?? window.screen?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
    }

    static func primaryVisibleFrame(candidates: [ScreenCandidate]) -> NSRect? {
        candidates.first { candidate in
            candidate.frame.contains(NSPoint.zero)
        }?.visibleFrame
    }

    @MainActor
    static func center(_ window: NSWindow, inVisibleFrame visibleFrame: NSRect) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrameOrigin(centeredOrigin(windowSize: window.frame.size, in: visibleFrame))
    }

    static func centeredOrigin(windowSize: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.minX + (visibleFrame.width - windowSize.width) / 2,
            y: visibleFrame.minY + (visibleFrame.height - windowSize.height) / 2
        )
    }

    static func visibleFrame(containing point: NSPoint, candidates: [ScreenCandidate]) -> NSRect? {
        candidates.first { candidate in
            candidate.frame.contains(point)
        }?.visibleFrame
    }
}
