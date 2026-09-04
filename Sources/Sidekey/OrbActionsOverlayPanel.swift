import AppKit
import SwiftUI
import Combine

/// Floating, non-activating, borderless panel that hosts the
/// round-3 actions cluster. Layered ON TOP of `FloatingDotPanel`
/// (orb) and `KeybindingsHintPanel` (helper chip) — neither of those
/// resizes anymore. The overlay panel itself orders in/out on hover
/// and renders a darkened rounded-rect background + the 3-row
/// `OrbActionsView` inside.
///
/// Sized to the union of the orb panel frame and the helper panel
/// frame (when visible), expanded by the `overlayPadding` margin.
/// That envelope gives the rounded-rect background enough negative
/// space to read against both light and dark wallpapers without
/// touching the orb / helper glyphs.
///
/// Lifecycle:
///   * Created at app launch (or when the orb panel first appears),
///     kept alive but ordered OUT while `orbHovered == false`.
///   * On `orbHovered == true`: re-compute the frame from the live
///     orb + helper frames, `orderFrontRegardless`, fade in via the
///     SwiftUI root.
///   * On `orbHovered == false`: SwiftUI fades the contents to 0,
///     then the panel orders out (deferred so the fade-out is
///     visible).
@MainActor
final class OrbActionsOverlayPanel: NSPanel {
    private let orbFrameProvider: () -> NSRect
    private let hintFrameProvider: () -> NSRect?
    private let onAction: (OrbActionsView.IconID) -> Void
    private var cancellables = Set<AnyCancellable>()

    /// Same staged-fade duration as round 2 — kept so the panel
    /// stays visible long enough for the SwiftUI fade to play out.
    static let fadeDurationSeconds: Double = 0.22

    /// Monotonic generation counter for deferred order-out actions.
    /// If the user mouses out and back in within the fade window,
    /// the older order-out is invalidated by the bump and skipped.
    private var orderOutGeneration: UInt64 = 0

    init(
        orbFrame: @escaping () -> NSRect,
        hintFrame: @escaping () -> NSRect?,
        onAction: @escaping (OrbActionsView.IconID) -> Void = { _ in }
    ) {
        self.orbFrameProvider = orbFrame
        self.hintFrameProvider = hintFrame
        self.onAction = onAction

        let initialFrame = Self.overlayFrame(orb: orbFrame(), hint: hintFrame())
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        // Match the orb panel (`.statusBar`) so the overlay orders above
        // the hint (`.statusBar - 1`) and beats the Dock + fullscreen
        // chrome. Within the `.statusBar` tier the overlay calls
        // `orderFrontRegardless` on hover-in, so AppKit places it above
        // the orb. Previously we used `.floating` (3) which sat BELOW
        // the Dock and vanished on fullscreen Spaces.
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        // The overlay needs clicks — the three row buttons live inside
        // its SwiftUI root. `.nonactivatingPanel` style keeps Sidekey
        // from snatching focus when a click lands.
        self.ignoresMouseEvents = false
        self.isMovable = false
        self.hidesOnDeactivate = false

        let host = NSHostingView(
            rootView: OrbActionsOverlayRoot(state: AppState.shared, onAction: onAction)
        )
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = host

        // Hover state drives both the frame recompute and the
        // order-in / deferred-order-out lifecycle.
        AppState.shared.$orbHovered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hovered in
                self?.applyHoverVisibility(hovered: hovered)
            }
            .store(in: &cancellables)

        // Screen change → resize the panel so it still lines up with
        // the orb + helper after the system moves them.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshFrame()
        }
    }

    private func refreshFrame() {
        let newFrame = Self.overlayFrame(
            orb: orbFrameProvider(),
            hint: hintFrameProvider()
        )
        setFrame(newFrame, display: true, animate: false)
    }

    /// Padding around the orb+helper union inside the overlay panel's
    /// frame. Round 4 bumped from 8pt to 12pt to give the wider
    /// rounded-rect (which now needs to fit a 28pt icon + magnified
    /// row) more visible negative space against the wallpaper.
    static let outerPadding: CGFloat = 12

    /// Pure-logic helper: the overlay panel's screen-space frame is
    /// `OrbHoverDetector.overlayEnvelope(...)` with a minimum cluster
    /// size derived from `OrbActionsView`'s constants. Exposed at the
    /// panel level so a future caller (e.g. `OrbHoverController`)
    /// can query the overlay's projected frame without instantiating
    /// the panel.
    ///
    /// Round 4: passes `minimumClusterWidth` / `minimumClusterHeight`
    /// so the envelope expands when the raw orb+helper union is
    /// narrower than the actions cluster needs. Otherwise the
    /// magnified row (especially with `.center` anchor + the 28pt
    /// icon glyphs) would clip against the rounded-rect frame.
    static func overlayFrame(orb: NSRect, hint: NSRect?) -> NSRect {
        OrbHoverDetector.overlayEnvelope(
            orb: orb,
            hint: hint,
            padding: outerPadding,
            minimumClusterWidth: OrbActionsView.minimumOverlayClusterWidth,
            minimumClusterHeight: OrbActionsView.minimumOverlayClusterHeight
        )
    }

    /// Orders the panel in on hover-in (synchronously, so the SwiftUI
    /// fade-in has a frame to render into). On hover-out, defers the
    /// order-out by `fadeDurationSeconds` so the SwiftUI fade-out is
    /// visible before the pixels disappear.
    @MainActor
    private func applyHoverVisibility(hovered: Bool) {
        if hovered {
            refreshFrame()
            orderFrontRegardless()
            // Bump generation so any in-flight order-out from a
            // previous "hovered = false" tick gets invalidated.
            orderOutGeneration &+= 1
            return
        }
        orderOutGeneration &+= 1
        let generation = orderOutGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDurationSeconds) { [weak self] in
            guard let self = self else { return }
            // A newer hover cycle happened during the fade — skip.
            guard self.orderOutGeneration == generation else { return }
            // Belt-and-braces: re-check the live state.
            guard !AppState.shared.orbHovered else { return }
            self.orderOut(nil)
        }
    }
}

/// SwiftUI root inside `OrbActionsOverlayPanel`. Composes the
/// darkened rounded-rect background + the 3-row cluster. Drives its
/// own opacity from `AppState.shared.orbHovered` so the fade animation
/// runs even though the panel itself orders in synchronously.
private struct OrbActionsOverlayRoot: View {
    @ObservedObject var state: AppState
    let onAction: (OrbActionsView.IconID) -> Void

    /// Match the staged-fade timing from round 2 — orb fades on the
    /// first half-cycle, the overlay contents fade in on the second.
    private static let halfFade: Double = 0.11

    /// Background rounded-rect radius. Picked to feel like the same
    /// affordance family as the `HotkeyHintView` capsule but slightly
    /// blockier so the rectangle reads as "a container" rather than
    /// "another chip".
    private static let cornerRadius: CGFloat = 14

    /// Inner padding for the cluster inside the rounded rect — the
    /// overlay panel's outer envelope already includes `outerPadding`
    /// of negative space around the orb+hint union, but this padding
    /// is the visual cushion between the rounded edge and the row
    /// content (`HotkeyHintView` + icon). Round 4: horizontal pulled
    /// from `OrbActionsView.frameContentHorizontalPadding` so the
    /// magnified-row math (anchored `.center`, peak 1.30) stays in
    /// sync with the rendered frame. Vertical is smaller because the
    /// cluster's vertical extent grows less on per-row magnification.
    private static let contentHorizontalPadding: CGFloat = OrbActionsView.frameContentHorizontalPadding
    private static let contentVerticalPadding: CGFloat = OrbActionsView.frameContentVerticalPadding

    var body: some View {
        ZStack {
            // Darkened rounded-rect container. `.ultraThinMaterial`
            // blurs the wallpaper behind it; the dark wash over the
            // material makes the frame read on light/white wallpapers
            // too (Maxim's explicit requirement). The thin white
            // stroke adds definition on dark wallpapers where the
            // dark wash blends into the bloom.
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )

            // Three-row cluster, padded inside the rounded rect.
            OrbActionsView(onAction: onAction)
                .padding(.horizontal, Self.contentHorizontalPadding)
                .padding(.vertical, Self.contentVerticalPadding)
        }
        // Fade in on the second half-cycle (after the orb fades out),
        // fade out on the first half-cycle (before the orb fades in).
        // Mirrors round 2's staging.
        .opacity(state.orbHovered ? 1 : 0)
        .animation(
            .easeInOut(duration: Self.halfFade)
                .delay(state.orbHovered ? Self.halfFade : 0),
            value: state.orbHovered
        )
    }
}
