import AppKit
import Combine
import QuartzCore
import SwiftUI

/// State of the Secure Input holder badge to the right of the island.
@MainActor
final class SecureInputHolderModel: ObservableObject {
    @Published var badge: SecureInputHolderBadge?
    /// Full strength right after a blocked attempt; dimmed otherwise.
    @Published var emphasized = false
    @Published var hovered = false
    /// The island's compact height, so the pill matches it.
    @Published var height: CGFloat = 32
}

/// The macOS wrong-password shake, as horizontal offsets in points. The
/// window itself moves, as the login window does, so the panel can stay
/// exactly the size of the pill.
enum SecureInputShake {
    static let offsets: [CGFloat] = [-9, 9, -7, 7, -4, 4, 0]
    static let duration: TimeInterval = 0.4
}

enum SecureInputHolderMetrics {
    static let iconSide: CGFloat = 20
    static let labelSpacing: CGFloat = 8
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    static func horizontalPadding(height: CGFloat) -> CGFloat { (height - iconSide) / 2 }

    /// A circle when collapsed; on hover it grows rightward to fit the label.
    static func pillWidth(label: String?, height: CGFloat) -> CGFloat {
        guard let label else { return height }
        let text = (label as NSString).size(withAttributes: [.font: labelFont]).width.rounded(.up) + 2
        return height + labelSpacing + text
    }
}

struct SecureInputHolderView: View {
    @ObservedObject var model: SecureInputHolderModel

    var body: some View {
        ZStack(alignment: .leading) {
            if let badge = model.badge {
                pill(badge).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: model.badge)
        .ignoresSafeArea()
    }

    private func pill(_ badge: SecureInputHolderBadge) -> some View {
        HStack(spacing: SecureInputHolderMetrics.labelSpacing) {
            icon(badge)
                .frame(width: SecureInputHolderMetrics.iconSide, height: SecureInputHolderMetrics.iconSide)
            if model.hovered {
                Text(badge.label)
                    .font(Font(SecureInputHolderMetrics.labelFont))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, SecureInputHolderMetrics.horizontalPadding(height: model.height))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: model.height)
        .background(Capsule(style: .continuous).fill(Color.black))
        .opacity(model.emphasized || model.hovered ? 1 : 0.7)
        .animation(.easeOut(duration: 0.15), value: model.hovered)
        .animation(.easeOut(duration: 0.2), value: model.emphasized)
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

/// A non-activating badge with the Secure Input holder's logo, just to the
/// right of the island. It never takes focus. The window is exactly the
/// pill, so it never swallows a menu-bar click beside it (a window that
/// accepts the mouse eats clicks where its content does not hit-test).
// WHY: .project-docs/decisions/2026-11-26-secure-input-holder.md
@MainActor
final class SecureInputHolderPanel: NSPanel, SecureInputHolderPresenting {
    /// Created on the first badge, so launching Whytap makes no window.
    private static var instance: SecureInputHolderPanel?
    static var shared: SecureInputHolderPanel {
        if let instance { return instance }
        let panel = SecureInputHolderPanel()
        instance = panel
        return panel
    }

    /// The Settings switch, applied to a badge already on screen, exactly as
    /// `IslandPanel` applies it.
    static func setScreenshotProtectionEnabled(_ enabled: Bool) {
        instance?.sharingType = enabled ? .none : .readOnly
    }

    static let gapFromIsland: CGFloat = 6
    /// How long a shaken badge stays at full strength (or at all, when the
    /// holder is not stuck in the background) before it fades.
    static let emphasisDuration: TimeInterval = 2.8

    private let model = SecureInputHolderModel()
    private var persistent = false
    private var fadeWork: DispatchWorkItem?
    private var hoverObservation: AnyCancellable?

    private init() {
        let screen = IslandScreenResolver.currentDescriptor()
        let frame = Self.frame(on: screen, width: Self.islandHeight(on: screen))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isMovable = false
        hidesOnDeactivate = false; isFloatingPanel = true; ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        level = .screenSaver
        let host = NSHostingView(rootView: SecureInputHolderView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
        hoverObservation = model.$hovered.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reposition() }
        }
        // Follow the island to another display or after a disconnect, as
        // the Notify panel does.
        for name in [NSApplication.didChangeScreenParametersNotification, IslandScreenResolver.selectionDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var isShowing: Bool { model.badge != nil }

    @objc private func screenDidChange() {
        guard model.badge != nil else { return }
        reposition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    static func islandHeight(on screen: IslandScreenDescriptor) -> CGFloat {
        max(24, IslandFrameLayout.islandFrame(on: screen).height)
    }

    /// Top-flush with the island, starting just past its right edge.
    static func frame(on screen: IslandScreenDescriptor, width: CGFloat) -> NSRect {
        let island = IslandFrameLayout.islandFrame(on: screen)
        let height = islandHeight(on: screen)
        let x = island.maxX + gapFromIsland
        let fitted = max(height, min(width, screen.frame.maxX - x))
        return NSRect(x: x, y: island.maxY - height, width: fitted, height: height)
    }

    // MARK: SecureInputHolderPresenting

    func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool) {
        self.persistent = persistent
        sharingType = PrivacyPreferences.shared.screenshotProtectionEnabled ? .none : .readOnly
        model.badge = badge
        reposition()
        ignoresMouseEvents = false
        orderFrontRegardless()
        fadeWork?.cancel()
        guard shake else {
            model.emphasized = false
            return
        }
        model.emphasized = true
        shakeWindow()
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
        ignoresMouseEvents = true
        // Let the fade play before the window leaves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.model.badge == nil else { return }
            self.orderOut(nil)
        }
    }

    private func shakeWindow() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let origin = frame.origin
        let path = CGMutablePath()
        path.move(to: origin)
        for dx in SecureInputShake.offsets {
            path.addLine(to: CGPoint(x: origin.x + dx, y: origin.y))
        }
        let animation = CAKeyframeAnimation()
        animation.path = path
        animation.duration = SecureInputShake.duration
        animations = ["frameOrigin": animation]
        animator().setFrameOrigin(origin)
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
        let height = Self.islandHeight(on: screen)
        model.height = height
        let label = model.hovered ? model.badge?.label : nil
        let frame = Self.frame(on: screen, width: SecureInputHolderMetrics.pillWidth(label: label, height: height))
        setFrame(frame, display: true)
    }
}
