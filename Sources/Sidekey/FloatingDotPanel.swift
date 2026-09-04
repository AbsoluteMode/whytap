import AppKit
import SwiftUI
import Combine

private class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result == self ? nil : result
    }
}

/// Borderless, click-through, always-on-top panel that displays the orb.
/// Pinned near the bottom-right of the active screen.
final class FloatingDotPanel: NSPanel {
    private static let panelWidth: CGFloat = VoiceOrbView.canvasSize
    private static let collapsedHeight: CGFloat = VoiceOrbView.canvasSize
    private static let expandedHeight: CGFloat = VoiceOrbView.canvasSize
    /// Buffer added on top of every overlay panel's bottom anchor so a
    /// magnified or full-bar Dock can't paint over the orb cluster. The
    /// OS does NOT always subtract a magnified Dock's full visual size
    /// from `NSScreen.visibleFrame`, so we add an explicit cushion in
    /// addition to a `.statusBar` window level. Same value reused by
    /// `AgentTextInputPanel`, `AgentResponsePanel`, and
    /// `HistoryStripPanel` so the whole UI lifts together.
    static let dockSafeBottomMargin: CGFloat = 40
    /// Base anchor distance from `visible.minY` BEFORE the dock-safe
    /// buffer. Was 19pt before the glow-padding bump (`canvasSize` 41 →
    /// 57): a fixed bottom anchor + larger canvas would have pushed the
    /// orb's vertical centre UP by 8pt — visible drift from the
    /// position the user already learned. Subtracting half the canvas
    /// growth (8pt) preserves the orb's screen-space visual centre
    /// (`panel.minY + canvasSize/2`): old `19 + 41/2 = 39.5`, new
    /// `11 + 57/2 = 39.5` (above `visible.minY`, pre dock-safe buffer).
    /// The extra 16pt of transparent canvas grows DOWN past the
    /// previous panel bottom, but the panel still sits above the Dock
    /// because the dock-safe buffer (40pt) is applied on top — net
    /// panel bottom sits 11+40 = 51pt above `visible.minY`, > 40pt
    /// floor, so a Dock at any size is still cleared.
    private static let baseMarginBottom: CGFloat = 11
    private static let marginBottom: CGFloat = baseMarginBottom + dockSafeBottomMargin
    /// Right-edge inset for the panel's right side. Was 80pt before the
    /// glow-padding bump (`canvasSize` 41 → 57): a fixed right inset +
    /// larger canvas would have shifted the orb's horizontal centre
    /// LEFT by 8pt. Subtracting half the canvas growth (8pt) preserves
    /// the orb's visual centre (`panel.minX + canvasSize/2` from
    /// `visible.maxX`): old `80 + 41/2 = 100.5`, new
    /// `72 + 57/2 = 100.5`pt left of the right edge.
    private static let marginRight: CGFloat = 72

    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    /// Background-luminance observer retained for palette fallback and for
    /// legacy meeting-audio plumbing. The orb no longer starts screen
    /// capture from this panel; keeping screen observation off is more
    /// important than wallpaper-adaptive contrast.
    private let luminance = BackgroundLuminanceObserver.shared

    /// Resolves the keybindings-hint panel's current screen frame so the
    /// hover-region union covers both panels. Set externally by the
    /// owner (`AppDelegate`) after it creates the hint panel — the
    /// orb panel does not own the hint, but it owns the hover detection
    /// because the hover state is shared between the two surfaces.
    var hintFrameProvider: () -> NSRect? = { nil }

    /// Detects cursor entry into the orb+hint region and writes the
    /// result into `AppState.shared.orbHovered`. Started in `init` and
    /// torn down in `deinit`.
    private var hoverController: OrbHoverController?

    /// Resolves the actions-overlay panel's current screen frame so
    /// the hover detector can keep the cursor latched while it
    /// travels over the overlay (which extends past the orb + helper
    /// footprint). Set externally by `AppDelegate` after the overlay
    /// is constructed. `nil` when the overlay isn't on screen.
    var overlayFrameProvider: () -> NSRect? = { nil }

    init() {
        let frame = Self.bottomRightFrame(
            visibleFrame: IslandScreenResolver.currentVisibleFrame(),
            expanded: false
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        // `.statusBar` (25) sits above the Dock (`kCGDockWindowLevelKey`
        // ≈ 20) so a full-bar or magnified Dock can't paint over the orb
        // — same tier history panels picked up in PR #110 for the same
        // reason. The previous `.floating` (3) sat BELOW the Dock and
        // also vanished when the user switched into another app's
        // fullscreen Space (Maxim: "при включении ask mode не
        // показывается строка ввода в полноэкранном режиме").
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isMovable = false
        self.hidesOnDeactivate = false

        // The panel's SwiftUI root flips between the orb (idle) and the
        // three-icon actions row (cursor inside the orb+hint region).
        // `ClickThroughHostingView` lets the panel stay click-through
        // for any pixel SwiftUI marks as non-interactive — the orb does
        // not steal clicks while idle, but the action icons sit inside
        // hit-testable `Button` views so they do receive their own
        // events once the panel flips its `ignoresMouseEvents` bit off.
        let host = ClickThroughHostingView(
            rootView: FloatingDotPanelRoot(
                state: AppState.shared,
                luminance: luminance
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.collapsedHeight)
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

        // `NSWindow.didChangeScreenNotification` fires when this panel
        // crosses screen boundaries (multi-monitor swap). Without it the
        // BackgroundLuminanceObserver keeps sampling the old display
        // and the orb's palette never updates. See
        // `handlePanelScreenChange` for the restart logic.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelScreenChange),
            name: NSWindow.didChangeScreenNotification,
            object: self
        )

        AppState.shared.$toolsExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                self?.updateExpansion(expanded)
            }
            .store(in: &cancellables)

        AppState.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { phase in
                if phase != .idle && AppState.shared.toolsExpanded {
                    AppState.shared.toolsExpanded = false
                }
            }
            .store(in: &cancellables)

        AppState.shared.$agentPhase
            .receive(on: DispatchQueue.main)
            .sink { phase in
                if phase != .idle && AppState.shared.toolsExpanded {
                    AppState.shared.toolsExpanded = false
                }
            }
            .store(in: &cancellables)

        // Combine drop + agent phase into a single "is the orb visible?"
        // diagnostic signal. This used to start/stop screen sampling for
        // wallpaper-adaptive orb contrast; screen observation is no longer
        // part of the normal app lifecycle.
        Publishers
            .CombineLatest(AppState.shared.$phase, AppState.shared.$agentPhase)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, agentPhase in
                guard let self = self else { return }
                let visible = phase != .idle || agentPhase != .idle
                self.refreshLuminanceLifecycle(visible: visible)
            }
            .store(in: &cancellables)

        // Start the global+local cursor monitor. Round 3: the panel
        // itself NO LONGER resizes on hover (it stays a fixed
        // `VoiceOrbView.canvasSize` square at the bottom-right anchor —
        // Maxim's complaint was that growing the panel moved the orb's
        // screen-space position, since the orb stays centred inside the
        // panel).
        // The actions cluster now lives in a separate
        // `OrbActionsOverlayPanel` that orders itself in on hover.
        //
        // The controller's hover region is the orb ∪ helper ∪ overlay
        // (when visible) union, so the cursor stays latched while it
        // travels across the actions cluster even though the cluster
        // extends past the orb panel's frame.
        let hoverController = OrbHoverController(
            orbFrameProvider: { [weak self] in self?.frame ?? .zero },
            hintFrameProvider: { [weak self] in self?.hintFrameProvider() },
            overlayFrameProvider: { [weak self] in self?.overlayFrameProvider() }
        )
        hoverController.start()
        self.hoverController = hoverController
    }

    /// Forwards the orb's visibility into the observer for diagnostics and
    /// keeps the window-ID + sample region fresh. It intentionally does
    /// not start `BackgroundLuminanceObserver` anymore: that path creates a
    /// capture session and macOS shows the persistent screen observation
    /// indicator.
    private func refreshLuminanceLifecycle(visible: Bool) {
        luminance.setExcludedWindowID(CGWindowID(self.windowNumber))
        luminance.setSampleRegion(screenFrame: Self.luminanceSampleRect(for: self.frame))
        luminance.notePanelVisibilityChanged(isVisible: visible)
    }

    /// Computes the screen-space rect (Cocoa coords) the luminance
    /// observer should sample. Centred on the panel's frame and clamped
    /// to `BackgroundLuminanceObserver.sampleEdgePt` per side.
    static func luminanceSampleRect(for panelFrame: NSRect) -> NSRect {
        let edge = BackgroundLuminanceObserver.sampleEdgePt
        let centerX = panelFrame.midX
        let centerY = panelFrame.midY
        return NSRect(
            x: centerX - edge / 2,
            y: centerY - edge / 2,
            width: edge,
            height: edge
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // The OrbHoverController removes its own NSEvent monitors via
        // its own deinit — assigning nil here drops the last strong
        // reference so that deinit runs synchronously on this thread.
        hoverController = nil
    }

    // Borderless panels must override these to truly never become key/main.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showOnTop() {
        self.orderFrontRegardless()
    }

    @objc private func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let expanded = AppState.shared.toolsExpanded
            self.setFrame(
                Self.bottomRightFrame(
                    visibleFrame: IslandScreenResolver.currentVisibleFrame(),
                    expanded: expanded
                ),
                display: true
            )
            // Display config changed (resolution / arrangement / a
            // monitor was plugged or unplugged). Keep the observer's
            // diagnostic screen metadata fresh without starting capture.
            self.handlePanelScreenChange()
        }
    }

    /// Called whenever the panel crosses a screen boundary or the system
    /// display configuration changes. We still publish the current display
    /// and sample rect for diagnostics / legacy clients, but no longer
    /// restart screen capture for orb contrast.
    @objc private func handlePanelScreenChange() {
        let displayID = Self.currentDisplayID(for: self)
        // Publish the fresh sample region before noting the change —
        // this way if `restart()` reads `currentSampleRegion`, it gets
        // the post-move rect, not the pre-move one.
        luminance.setExcludedWindowID(CGWindowID(self.windowNumber))
        luminance.setSampleRegion(screenFrame: Self.luminanceSampleRect(for: self.frame))
        luminance.noteScreenChanged(toDisplayID: displayID)

    }

    /// Resolves the `CGDirectDisplayID` of the screen the panel is
    /// currently on. Falls back to `NSScreen.main` if `panel.screen` is
    /// nil (transient during boot), and to `0` if even that is missing.
    /// `0` is a sentinel "no display" — the observer treats it as
    /// equivalent to "no pipeline captured yet", so the next real
    /// notification still triggers a fresh capture.
    static func currentDisplayID(for panel: NSWindow) -> CGDirectDisplayID {
        let screen = panel.screen ?? NSScreen.main
        guard let info = screen?.deviceDescription,
              let number = info[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    @MainActor
    private func updateExpansion(_ expanded: Bool) {
        let newFrame = Self.bottomRightFrame(
            visibleFrame: IslandScreenResolver.currentVisibleFrame(),
            expanded: expanded
        )
        setFrame(newFrame, display: true, animate: false)

        if expanded {
            ignoresMouseEvents = true

            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self else { return }
                let screenPoint = event.locationInWindow
                if !self.frame.contains(screenPoint) {
                    DispatchQueue.main.async {
                        AppState.shared.toolsExpanded = false
                    }
                }
            }
        } else {
            ignoresMouseEvents = true

            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }

    /// Computes a frame anchored near the bottom-right of the given screen's
    /// `visibleFrame` (which excludes Dock and menu bar).
    /// The bottom edge (originY) stays fixed; height grows upward when expanded.
    static func bottomRightFrame(for screen: NSScreen?, expanded: Bool) -> NSRect {
        let visible = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return bottomRightFrame(visibleFrame: visible, expanded: expanded)
    }

    static func bottomRightFrame(visibleFrame visible: NSRect, expanded: Bool) -> NSRect {
        let height = expanded ? expandedHeight : collapsedHeight
        let originX = visible.maxX - panelWidth - marginRight
        let originY = visible.minY + marginBottom
        return NSRect(x: originX, y: originY, width: panelWidth, height: height)
    }
}

/// SwiftUI root view hosted inside `FloatingDotPanel`. Round 3: the
/// orb panel no longer cross-fades into the actions cluster — the
/// cluster lives in `OrbActionsOverlayPanel` on top. The orb just
/// fades to opacity 0 while hovered so the overlay can take over the
/// visual focus cleanly.
///
/// Staged with `OrbActionsOverlayRoot`'s fade (110ms half-cycle): the
/// orb here fades out in the first half (entering hover) before the
/// overlay's contents fade in during the second half, and vice versa
/// on exit. The hint panel (`KeybindingsHintView`) follows the same
/// staging, so all three surfaces feel synchronised.
struct FloatingDotPanelRoot: View {
    @ObservedObject var state: AppState
    @ObservedObject var luminance: BackgroundLuminanceObserver

    private let containerSize: CGFloat = VoiceOrbView.canvasSize

    /// Half-fade cycle. Mirrors `OrbActionsOverlayRoot.halfFade`.
    private static let halfFade: Double = 0.11

    var body: some View {
        DotView(state: state, luminance: luminance)
            .frame(width: containerSize, height: containerSize)
            // Fade out on the first half when entering hover, fade in
            // on the second half when leaving hover.
            .opacity(state.orbHovered ? 0 : 1)
            .animation(
                .easeInOut(duration: Self.halfFade)
                    .delay(state.orbHovered ? 0 : Self.halfFade),
                value: state.orbHovered
            )
    }
}
