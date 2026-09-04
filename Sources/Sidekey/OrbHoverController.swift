import AppKit

/// Owns the global / local `NSEvent` monitors that watch the cursor
/// position and flip `AppState.shared.orbHovered` when the cursor is
/// inside the floating orb area.
///
/// Round 3: the orb panel itself never resizes — it stays a fixed
/// `VoiceOrbView.canvasSize` square (post-shrink 41pt). The actions
/// cluster lives in a separate overlay panel
/// (`OrbActionsOverlayPanel`) that orders in on hover. The
/// controller's hover region is the union of (orb ∪ hint ∪ overlay
/// when visible) so the cursor stays latched while it travels over
/// the overlay's rounded-rect background — which extends past the
/// raw orb+hint footprint.
///
/// Why both global and local monitors:
/// - `addGlobalMonitorForEvents` fires when other apps are foreground
///   (the common case for a menu-bar app: Sidekey is rarely "active").
/// - `addLocalMonitorForEvents` fires when Sidekey itself is the
///   foreground app — happens when the Agent text input panel is open
///   or any Sidekey window has key focus.
/// Without both, the swap would not trigger reliably across the entire
/// Sidekey UI lifecycle. The same `OrbHoverDetector` math runs from
/// both callbacks so the state stays consistent regardless of which
/// monitor sees the event first.
@MainActor
final class OrbHoverController {
    /// Closure that resolves the orb panel's current screen-space
    /// frame. Lazy because the panel can move (screen change);
    /// the controller queries it every event tick so the hover
    /// region tracks live.
    private let orbFrameProvider: () -> NSRect
    /// Closure that resolves the hint panel's current frame, or `nil`
    /// when the hint panel is hidden (user clicked the eye-slash, or
    /// the panel hasn't been created yet).
    private let hintFrameProvider: () -> NSRect?
    /// Closure that resolves the actions-overlay panel's current
    /// frame, or `nil` when the overlay is ordered out (the common
    /// case while idle). Joining the overlay's frame into the hover
    /// region keeps the cursor latched while it travels over the
    /// rounded-rect background that extends past orb+hint.
    private let overlayFrameProvider: () -> NSRect?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(
        orbFrameProvider: @escaping () -> NSRect,
        hintFrameProvider: @escaping () -> NSRect?,
        overlayFrameProvider: @escaping () -> NSRect? = { nil }
    ) {
        self.orbFrameProvider = orbFrameProvider
        self.hintFrameProvider = hintFrameProvider
        self.overlayFrameProvider = overlayFrameProvider
    }

    /// Starts both monitors. Idempotent — calling twice does not
    /// double-register. The state of `AppState.shared.orbHovered` is
    /// updated synchronously from each event callback so the SwiftUI
    /// surface reacts within a frame.
    func start() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.tick()
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.tick()
                return event
            }
        }
    }

    /// Removes both monitors. Safe to call before `start()` or twice.
    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        // Reset the published flag so a panel that was mid-hover when
        // the controller stopped doesn't latch in actions mode.
        if AppState.shared.orbHovered {
            AppState.shared.orbHovered = false
        }
    }

    deinit {
        // Direct call to avoid actor-isolated `stop()` from a non-actor deinit.
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Reads the cursor's global location, asks `OrbHoverDetector`
    /// whether it's inside the orb ∪ hint ∪ overlay region, and writes
    /// the result into `AppState.shared.orbHovered`. Idempotent on
    /// equal state so the `@Published` does not fire when nothing
    /// changed.
    private func tick() {
        let cursor = NSEvent.mouseLocation
        let orb = orbFrameProvider()
        let hint = hintFrameProvider()
        let overlay = overlayFrameProvider()
        let next = OrbHoverDetector.isHovering(
            cursor: cursor,
            orb: orb,
            hint: hint,
            overlay: overlay
        )
        if AppState.shared.orbHovered != next {
            AppState.shared.orbHovered = next
        }
    }
}
