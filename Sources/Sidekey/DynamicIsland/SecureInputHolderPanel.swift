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
    /// Taller than `height` when the hover label wraps.
    @Published var pillHeight: CGFloat = 32
    /// Set when the label does not fit on one line beside the island: it
    /// wraps at this width instead of running off the screen.
    @Published var wrapWidth: CGFloat?
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

    /// Kept free between the pill and the screen's right edge.
    static let screenMargin: CGFloat = 8
    static let wrappedVerticalPadding: CGFloat = 7
    static let minimumWrapWidth: CGFloat = 80

    /// A circle when collapsed; on hover it grows rightward to fit the label.
    static func pillWidth(label: String?, height: CGFloat) -> CGFloat {
        guard let label else { return height }
        return height + labelSpacing + singleLineWidth(label)
    }

    static func singleLineWidth(_ label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: labelFont]).width.rounded(.up) + 2
    }

    struct Layout: Equatable {
        var size: CGSize
        /// Nil: one line. Otherwise the label wraps at this width.
        var wrapWidth: CGFloat?
    }

    /// The pill for a label within `maxWidth` (from the pill's left edge to
    /// the screen margin): one line when it fits, otherwise the label wraps
    /// and the pill grows downward, so the whole text stays readable.
    // WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md
    static func layout(label: String?, height: CGFloat, maxWidth: CGFloat) -> Layout {
        let oneLine = pillWidth(label: label, height: height)
        guard let label, oneLine > maxWidth else { return Layout(size: CGSize(width: oneLine, height: height)) }
        let wrap = max(minimumWrapWidth, maxWidth - height - labelSpacing).rounded(.down)
        let text = (label as NSString).boundingRect(
            with: CGSize(width: wrap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: labelFont]).height.rounded(.up)
        let pillHeight = max(height, text + 2 * wrappedVerticalPadding)
        return Layout(size: CGSize(width: height + labelSpacing + wrap, height: pillHeight), wrapWidth: wrap)
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
                label(badge.label)
                    .font(Font(SecureInputHolderMetrics.labelFont))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, SecureInputHolderMetrics.horizontalPadding(height: model.height))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: model.pillHeight)
        .background(RoundedRectangle(cornerRadius: model.height / 2, style: .continuous).fill(Color.black))
        .opacity(model.emphasized || model.hovered ? 1 : 0.7)
        .animation(.easeOut(duration: 0.15), value: model.hovered)
        .animation(.easeOut(duration: 0.2), value: model.emphasized)
        .onHover { model.hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.label)
    }

    @ViewBuilder
    private func label(_ text: String) -> some View {
        if let width = model.wrapWidth {
            Text(text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
        } else {
            Text(text).lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder
    private func icon(_ badge: SecureInputHolderBadge) -> some View {
        if let app = badge.app, let image = NSRunningApplication(processIdentifier: app.pid)?.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: badge.fallbackSymbol)
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
final class SecureInputHolderPanel: NSPanel, HotkeyBlockerBadgeSurface {
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

    /// Called when a shaken, non-persistent badge fades on its own, so the
    /// badge stack can bring back the badge it covered.
    var onSelfDismiss: (() -> Void)?

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
        frame(on: screen, size: CGSize(width: width, height: islandHeight(on: screen)))
    }

    /// A wrapped label makes the pill taller; it grows downward.
    static func frame(on screen: IslandScreenDescriptor, size: CGSize) -> NSRect {
        let island = IslandFrameLayout.islandFrame(on: screen)
        let height = max(islandHeight(on: screen), size.height)
        let x = island.maxX + gapFromIsland
        let fitted = max(islandHeight(on: screen), min(size.width, screen.frame.maxX - x))
        return NSRect(x: x, y: island.maxY - height, width: fitted, height: height)
    }

    /// Room for the pill between the island and the screen's right margin.
    static func availableWidth(on screen: IslandScreenDescriptor) -> CGFloat {
        let x = IslandFrameLayout.islandFrame(on: screen).maxX + gapFromIsland
        return screen.frame.maxX - SecureInputHolderMetrics.screenMargin - x
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
        if persistent {
            model.emphasized = false
        } else {
            dismiss()
            onSelfDismiss?()
        }
    }

    private func reposition() {
        let screen = IslandScreenResolver.currentDescriptor()
        let height = Self.islandHeight(on: screen)
        model.height = height
        let label = model.hovered ? model.badge?.label : nil
        let layout = SecureInputHolderMetrics.layout(label: label, height: height,
                                                     maxWidth: Self.availableWidth(on: screen))
        model.pillHeight = layout.size.height
        model.wrapWidth = layout.wrapWidth
        setFrame(Self.frame(on: screen, size: layout.size), display: true)
    }
}
