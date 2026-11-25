import AppKit
import SwiftUI

/// Clicks on the subtitle overlay's own buttons (× and Stop / Start / Cancel),
/// dispatched by the panel's `sendEvent`. The overlay floats over a video in
/// another app: Whytap is inactive and the panel is not key, and the
/// AppKit-to-SwiftUI bridge can drop that first-mouse click before any
/// SwiftUI button sees it. `acceptsFirstMouse` on the hosting view does not
/// help (see docs/bugs/2026-09-04-island-answer-close-first-mouse.md). The
/// window always gets the event, so it checks the buttons' measured frames,
/// as the island does (`IslandHoverHitBridge`).
///
/// A press belongs to the one button view, action and frame it began on.
/// It acts on mouse-up only if all three are unchanged and the panel is still
/// shown. Leaving the button, hiding the panel or a new mode cancels it for
/// good, and its mouse-up is still consumed.
///
/// A click on the text translation (`copy`) copies it. The press is only
/// watched and goes on to the selectable text, so a drag still selects part of
/// it: a mouse-up within `clickSlop` of a single click's mouse-down copies.
// WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
// WHY: .project-docs/decisions/2026-11-24-click-to-copy-translation.md
@MainActor
final class SubtitleOverlayHitTargets: ObservableObject {
    enum Control: Hashable { case close, session, copy }

    /// How far a press on the translation may move and still be a click.
    static let clickSlop: CGFloat = 3

    /// The control under a press that would still act, for its pressed look.
    @Published private(set) var pressed: Control?

    private struct Entry { weak var view: SubtitleOverlayHitReporterView? }
    private struct Press {
        let control: Control
        weak var view: SubtitleOverlayHitReporterView?
        let action: String
        let frame: CGRect
    }
    private var reporters: [Control: Entry] = [:]
    private var press: Press?
    /// A watched press on the translation that has not moved yet.
    private var copyPress: (view: SubtitleOverlayHitReporterView, start: CGPoint)?
    /// The current mouse-down was ours: its drags and mouse-up are consumed.
    private var consumes = false

    fileprivate func register(_ view: SubtitleOverlayHitReporterView) {
        if let press, press.control == view.control, press.view !== view || press.action != view.action {
            cancelPress()
        }
        reporters[view.control] = Entry(view: view)
    }

    fileprivate func unregister(_ view: SubtitleOverlayHitReporterView) {
        if reporters[view.control]?.view === view { reporters[view.control] = nil }
        if press?.view === view || copyPress?.view === view { cancelPress() }
    }

    /// Drops the press in progress (the panel hid or changed mode); its
    /// mouse-up is still consumed and does nothing.
    func cancelPress() {
        press = nil
        copyPress = nil
        if pressed != nil { pressed = nil }
    }

    private func shownView(_ control: Control, in window: NSWindow) -> SubtitleOverlayHitReporterView? {
        guard window.isVisible, let view = reporters[control]?.view, view.window === window,
              !view.isHiddenOrHasHiddenAncestor else { return nil }
        return view
    }

    private func frame(of view: SubtitleOverlayHitReporterView) -> CGRect {
        view.convert(view.bounds, to: nil)
    }

    /// The window frame of a shown control, if it is on screen in `window`.
    func frame(of control: Control, in window: NSWindow) -> CGRect? {
        guard let view = shownView(control, in: window) else { return nil }
        let frame = control == .copy ? view.convert(view.visibleRect, to: nil) : frame(of: view)
        return frame.isEmpty ? nil : frame
    }

    /// True while the press is still on the view, action and frame it began on.
    private func pressHolds(at point: CGPoint, in window: NSWindow) -> Bool {
        guard let press, let view = press.view, shownView(press.control, in: window) === view,
              view.action == press.action else { return false }
        let now = frame(of: view)
        return now == press.frame && now.contains(point)
    }

    /// Handles a mouse event aimed at a control; true when it was consumed.
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        handle(event, in: window, buttons: true)
    }

    /// The Toolbox pane sits in the Settings window, whose events this does
    /// not see: a local monitor hands its clicks to the copy target only, and
    /// always passes them on. Its buttons stay ordinary SwiftUI buttons.
    func startLocalCopyDispatch() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            guard let window = event.window else { return event }
            MainActor.assumeIsolated { _ = self?.handle(event, in: window, buttons: false) }
            return event
        }
    }

    func stopLocalCopyDispatch() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        cancelPress()
    }

    private var localMonitor: Any?

    private func handle(_ event: NSEvent, in window: NSWindow, buttons handlesButtons: Bool) -> Bool {
        let point = event.locationInWindow
        switch event.type {
        case .leftMouseDown:
            cancelPress()
            consumes = false
            let buttons = handlesButtons ? [Control.close, .session] : []
            if let control = buttons.first(where: { frame(of: $0, in: window)?.contains(point) == true }),
               let view = shownView(control, in: window) {
                press = Press(control: control, view: view, action: view.action, frame: frame(of: view))
                pressed = control
                consumes = true
                return true
            }
            // Control-click is the context menu's; a double click selects a
            // word. The text keeps the press either way.
            if !event.modifierFlags.contains(.control), event.clickCount <= 1,
               frame(of: .copy, in: window)?.contains(point) == true, let view = shownView(.copy, in: window) {
                copyPress = (view, point)
                pressed = .copy
            }
            return false
        case .leftMouseDragged:
            if let copyPress, hypot(point.x - copyPress.start.x, point.y - copyPress.start.y) > Self.clickSlop {
                cancelPress()
            }
            guard consumes else { return false }
            if press != nil, !pressHolds(at: point, in: window) { cancelPress() }
            return true
        case .leftMouseUp:
            guard consumes || copyPress != nil else { return false }
            let consumed = consumes
            var action = consumes && pressHolds(at: point, in: window) ? press?.view?.activate : nil
            if let copyPress, shownView(.copy, in: window) === copyPress.view,
               frame(of: .copy, in: window)?.contains(point) == true,
               hypot(point.x - copyPress.start.x, point.y - copyPress.start.y) <= Self.clickSlop {
                action = copyPress.view.activate
            }
            cancelPress()
            consumes = false
            action?()
            return consumed
        default:
            return false
        }
    }
}

/// Reports a button's frame and current action to `SubtitleOverlayHitTargets`;
/// it never takes the mouse itself.
final class SubtitleOverlayHitReporterView: NSView {
    let control: SubtitleOverlayHitTargets.Control
    weak var targets: SubtitleOverlayHitTargets?
    /// Names what `activate` does now ("stop", "start", "close", "copy"): a press
    /// never fires an action other than the one it began on.
    var action: String
    var activate: () -> Void

    init(control: SubtitleOverlayHitTargets.Control, targets: SubtitleOverlayHitTargets?, action: String,
         activate: @escaping () -> Void) {
        self.control = control
        self.targets = targets
        self.action = action
        self.activate = activate
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            if window == nil { targets?.unregister(self) } else { targets?.register(self) }
        }
    }
}

struct SubtitleOverlayHitReporter: NSViewRepresentable {
    let control: SubtitleOverlayHitTargets.Control
    let targets: SubtitleOverlayHitTargets?
    let action: String
    let activate: () -> Void

    func makeNSView(context: Context) -> SubtitleOverlayHitReporterView {
        SubtitleOverlayHitReporterView(control: control, targets: targets, action: action, activate: activate)
    }

    func updateNSView(_ view: SubtitleOverlayHitReporterView, context: Context) {
        view.action = action
        view.activate = activate
        if view.window != nil { targets?.register(view) }
    }

    static func dismantleNSView(_ view: SubtitleOverlayHitReporterView, coordinator: ()) {
        MainActor.assumeIsolated { view.targets?.unregister(view) }
    }
}
