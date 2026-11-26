import AppKit
import SwiftUI

/// State of the Secure Input holder badge to the right of the island.
@MainActor
final class SecureInputHolderModel: ObservableObject {
    @Published var badge: SecureInputHolderBadge?
    /// Bumped once per shake; drives the keyframe animation.
    @Published var shakeCount = 0
    /// Full strength right after a blocked attempt; dimmed otherwise.
    @Published var emphasized = false
    @Published var hovered = false
    /// The island's compact height, so the pill matches it.
    @Published var height: CGFloat = 32
}

/// The macOS wrong-password shake, as horizontal offsets in points.
enum SecureInputShake {
    static let offsets: [CGFloat] = [-9, 9, -7, 7, -4, 4, 0]
    static let step: TimeInterval = 0.055
    static var duration: TimeInterval { step * Double(offsets.count) }
}

struct SecureInputHolderView: View {
    @ObservedObject var model: SecureInputHolderModel
    let onRect: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let iconSide: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let badge = model.badge {
                pill(badge)
                    .background(GeometryReader { geometry in
                        let rect = geometry.frame(in: .named("secure-input-panel"))
                        Color.clear.onAppear { onRect(rect) }
                            .onChange(of: rect) { _, value in onRect(value) }
                    })
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "secure-input-panel")
        .animation(.easeOut(duration: 0.18), value: model.badge)
        .ignoresSafeArea()
    }

    private func pill(_ badge: SecureInputHolderBadge) -> some View {
        let still = reduceMotion
        return HStack(spacing: 8) {
            icon(badge)
                .frame(width: Self.iconSide, height: Self.iconSide)
            if model.hovered {
                Text(badge.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, (model.height - Self.iconSide) / 2)
        .frame(height: model.height)
        .background(Capsule(style: .continuous).fill(Color.black))
        .opacity(model.emphasized || model.hovered ? 1 : 0.7)
        .animation(.easeOut(duration: 0.15), value: model.hovered)
        .animation(.easeOut(duration: 0.2), value: model.emphasized)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shakeCount) { content, offset in
            content.offset(x: still ? 0 : offset)
        } keyframes: { _ in
            KeyframeTrack {
                for offset in SecureInputShake.offsets {
                    LinearKeyframe(offset, duration: SecureInputShake.step)
                }
            }
        }
        .onHover { model.hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.label)
    }

    @ViewBuilder
    private func icon(_ badge: SecureInputHolderBadge) -> some View {
        if let app = badge.app, let image = NSRunningApplication(processIdentifier: app.pid)?.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "lock.fill")
                .resizable().scaledToFit()
                .foregroundStyle(.white)
                .padding(2)
        }
    }
}

private final class SecureInputHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: NSRect = .zero
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// A non-activating badge with the Secure Input holder's logo, just to the
/// right of the island. It never takes focus and only the pill itself
/// receives the mouse (for the hover label).
// WHY: .project-docs/decisions/2026-11-26-secure-input-holder.md
@MainActor
final class SecureInputHolderPanel: NSPanel, SecureInputHolderPresenting {
    static let shared = SecureInputHolderPanel()

    static let gapFromIsland: CGFloat = 6
    static let panelWidth: CGFloat = 380
    /// How long a shaken badge stays at full strength (or at all, when the
    /// holder is the frontmost app) before it fades.
    static let emphasisDuration: TimeInterval = 2.8

    private let model = SecureInputHolderModel()
    private var host: SecureInputHostingView<SecureInputHolderView>!
    private var persistent = false
    private var fadeWork: DispatchWorkItem?

    private init() {
        let frame = Self.frame(on: IslandScreenResolver.currentDescriptor())
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isMovable = false
        hidesOnDeactivate = false; isFloatingPanel = true; ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        level = .screenSaver
        let host = SecureInputHostingView(rootView: SecureInputHolderView(model: model, onRect: { _ in }))
        self.host = host
        host.rootView = SecureInputHolderView(model: model, onRect: { [weak self] rect in
            guard let self else { return }
            self.host.interactiveRect = NSRect(
                x: rect.minX, y: self.host.isFlipped ? rect.minY : self.host.bounds.height - rect.maxY,
                width: rect.width, height: rect.height)
        })
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    static func islandHeight(on screen: IslandScreenDescriptor) -> CGFloat {
        max(24, IslandFrameLayout.islandFrame(on: screen).height)
    }

    /// Top-flush with the island, starting just past its right edge.
    static func frame(on screen: IslandScreenDescriptor) -> NSRect {
        let island = IslandFrameLayout.islandFrame(on: screen)
        let height = islandHeight(on: screen)
        let x = island.maxX + gapFromIsland
        let width = max(height, min(panelWidth, screen.frame.maxX - x))
        return NSRect(x: x, y: island.maxY - height, width: width, height: height)
    }

    // MARK: SecureInputHolderPresenting

    func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool) {
        self.persistent = persistent
        sharingType = PrivacyPreferences.shared.screenshotProtectionEnabled ? .none : .readOnly
        reposition()
        model.badge = badge
        ignoresMouseEvents = false
        orderFrontRegardless()
        fadeWork?.cancel()
        guard shake else {
            model.emphasized = false
            return
        }
        model.emphasized = true
        model.shakeCount += 1
        let work = DispatchWorkItem { [weak self] in self?.endEmphasis() }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.emphasisDuration, execute: work)
    }

    func dismiss() {
        fadeWork?.cancel()
        fadeWork = nil
        persistent = false
        model.badge = nil
        model.emphasized = false
        model.hovered = false
        host.interactiveRect = .zero
        ignoresMouseEvents = true
        // Let the fade play before the window leaves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.model.badge == nil else { return }
            self.orderOut(nil)
        }
    }

    private func endEmphasis() {
        if model.hovered {
            // Keep it while the label is being read.
            let work = DispatchWorkItem { [weak self] in self?.endEmphasis() }
            fadeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            return
        }
        if persistent { model.emphasized = false } else { dismiss() }
    }

    private func reposition() {
        let screen = IslandScreenResolver.currentDescriptor()
        model.height = Self.islandHeight(on: screen)
        let frame = Self.frame(on: screen)
        setFrame(frame, display: false)
        host.frame = NSRect(origin: .zero, size: frame.size)
    }
}
