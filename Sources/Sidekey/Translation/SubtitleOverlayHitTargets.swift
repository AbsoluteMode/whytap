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
// WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
@MainActor
final class SubtitleOverlayHitTargets {
    enum Control: Hashable { case close, session }

    private struct Entry { weak var view: SubtitleOverlayHitReporterView? }
    private var reporters: [Control: Entry] = [:]
    /// The control a press began on; its mouse-up acts only inside it.
    private var pressed: Control?
    private var consumes = false

    fileprivate func register(_ view: SubtitleOverlayHitReporterView) { reporters[view.control] = Entry(view: view) }

    fileprivate func unregister(_ view: SubtitleOverlayHitReporterView) {
        if reporters[view.control]?.view === view { reporters[view.control] = nil }
        if pressed == view.control { pressed = nil }
    }

    /// The window frame of a shown control, if it is on screen in `window`.
    func frame(of control: Control, in window: NSWindow) -> CGRect? {
        guard let view = reporters[control]?.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else {
            return nil
        }
        let frame = view.convert(view.bounds, to: nil)
        return frame.isEmpty ? nil : frame
    }

    private func control(at point: CGPoint, in window: NSWindow) -> Control? {
        [Control.close, .session].first { frame(of: $0, in: window)?.contains(point) == true }
    }

    /// Handles a mouse event aimed at a control; true when it was consumed.
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        let point = event.locationInWindow
        switch event.type {
        case .leftMouseDown:
            pressed = control(at: point, in: window)
            consumes = pressed != nil
            return consumes
        case .leftMouseDragged:
            if let current = pressed, frame(of: current, in: window)?.contains(point) != true { pressed = nil }
            return consumes
        case .leftMouseUp:
            guard consumes else { return false }
            let action = pressed.flatMap { control in
                frame(of: control, in: window)?.contains(point) == true ? reporters[control]?.view?.activate : nil
            }
            pressed = nil
            consumes = false
            action?()
            return true
        default:
            return false
        }
    }
}

/// Reports a button's frame to `SubtitleOverlayHitTargets`; it never takes
/// the mouse itself.
final class SubtitleOverlayHitReporterView: NSView {
    let control: SubtitleOverlayHitTargets.Control
    weak var targets: SubtitleOverlayHitTargets?
    var activate: () -> Void

    init(control: SubtitleOverlayHitTargets.Control, targets: SubtitleOverlayHitTargets?, activate: @escaping () -> Void) {
        self.control = control
        self.targets = targets
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
    let activate: () -> Void

    func makeNSView(context: Context) -> SubtitleOverlayHitReporterView {
        SubtitleOverlayHitReporterView(control: control, targets: targets, activate: activate)
    }

    func updateNSView(_ view: SubtitleOverlayHitReporterView, context: Context) {
        view.activate = activate
        if view.window != nil { targets?.register(view) }
    }

    static func dismantleNSView(_ view: SubtitleOverlayHitReporterView, coordinator: ()) {
        MainActor.assumeIsolated { view.targets?.unregister(view) }
    }
}
