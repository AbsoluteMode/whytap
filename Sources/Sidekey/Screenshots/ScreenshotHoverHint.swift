import AppKit

/// The screenshot editor's own hover help.
///
/// AppKit tool tips never appear in the editor: Whytap stays inactive while its
/// nonactivating panels float at screen-saver level, and AppKit shows tool tips
/// only for the active app, below that level. Toolbar and settings controls
/// therefore keep their help text here and show it in one click-through panel
/// just above the editor. WHY: .project-docs/decisions/2026-11-22-shot-hover-hints.md
@MainActor
final class ScreenshotHoverHint {
    static let shared = ScreenshotHoverHint()
    /// Delay before the first hint; moving to the next control shows its hint at once.
    static let delay: TimeInterval = 0.45
    static let warmPeriod: TimeInterval = 0.4
    static let maxTextWidth: CGFloat = 260
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    private static let padding = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

    private(set) var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var pending: Task<Void, Never>?
    private weak var anchor: NSView?
    private(set) var visibleText: String?
    private var hiddenAt: Date = .distantPast
    private var clickMonitor: Any?

    /// The pointer entered `view`: show its help after the delay, or at once
    /// while a hint was just showing.
    func hover(_ view: NSView, text: String?) {
        pending?.cancel(); pending = nil
        guard let text, !text.isEmpty else { hide(); return }
        anchor = view
        watchClicks()
        if visibleText != nil || Date().timeIntervalSince(hiddenAt) < Self.warmPeriod {
            show(text, for: view); return
        }
        pending = Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(nanoseconds: UInt64(Self.delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let view, self.anchor === view else { return }
            self.show(text, for: view)
        }
    }

    /// The pointer left `view`; another control's hint stays.
    func leave(_ view: NSView) {
        guard anchor === view else { return }
        hide()
    }

    func hide() {
        pending?.cancel(); pending = nil; anchor = nil
        if visibleText != nil { hiddenAt = Date() }
        visibleText = nil
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
    }

    /// A click or key press hides the hint, as with AppKit tool tips; a pop-up
    /// menu opened by that click is never covered by it.
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.hide(); return event
        }
    }

    func show(_ text: String, for view: NSView) {
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { hide(); return }
        let (panel, size) = prepare(text)
        let anchorRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = window.screen?.frame ?? window.frame
        panel.setFrame(Self.frame(anchor: anchorRect, size: size, screen: screen), display: true)
        anchor = view; visibleText = text
        panel.orderFrontRegardless()
    }

    /// Sets the hint's text and returns its panel with the size it needs.
    func prepare(_ text: String) -> (NSPanel, CGSize) {
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        let textSize = label.sizeThatFits(NSSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(min(Self.maxTextWidth, textSize.width)) + Self.padding.left + Self.padding.right,
                          height: ceil(textSize.height) + Self.padding.top + Self.padding.bottom)
        return (panel, size)
    }

    /// Below the control, centered on it and kept on its screen; above it
    /// when there is no room below.
    static func frame(anchor: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 6, margin: CGFloat = 4) -> CGRect {
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
        if origin.y < screen.minY + margin { origin.y = anchor.maxY + gap }
        origin.y = min(max(origin.y, screen.minY + margin), screen.maxY - margin - size.height)
        origin.x = min(max(origin.x, screen.minX + margin), screen.maxX - margin - size.width)
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .toolTip; background.state = .active; background.blendingMode = .behindWindow
        background.wantsLayer = true; background.layer?.cornerRadius = 6; background.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: 0); label.textColor = .labelColor
        label.preferredMaxLayoutWidth = Self.maxTextWidth
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.padding.left),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.padding.right),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.padding.top),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.padding.bottom)
        ])
        panel.contentView = background
        self.panel = panel
        return panel
    }
}
