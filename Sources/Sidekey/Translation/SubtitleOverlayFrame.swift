import AppKit

/// Where the floating Subtitles overlay sits and how big it is. The user drags
/// the box anywhere and resizes it by its edges and corners; the frame is
/// remembered across launches and restored on the display it was left on.
/// When that display is gone, the remembered size returns at the usual place
/// at the bottom of the island's display. The box fills the panel except for
/// a thin transparent `margin` (its shadow), so the panel's frame is what the
/// user sees and resizes.
// WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
enum SubtitleOverlayFrame {
    static let defaultsKey = "sidekey.translation.subtitleFrame"
    /// The first size: five lines of pairs, as the original overlay.
    static let defaultSize = NSSize(width: 760, height: 190)
    /// The smallest box that still holds its controls, a problem's message
    /// and its button (checked by offscreen renders at this size).
    static let minimumSize = NSSize(width: 480, height: 150)
    /// The transparent band around the box, where its shadow falls.
    static let margin: CGFloat = 10
    /// How far inside the box's edge a press still resizes instead of moving.
    static let grip: CGFloat = 6
    /// Along an edge, this close to a corner a press resizes both ways.
    static let cornerGrip: CGFloat = 18
    /// The overlay starts this far above the bottom of the visible frame.
    static let bottomInset: CGFloat = 72

    /// Which edges a press moves: -1 the left or bottom edge, 1 the right or
    /// top edge, 0 neither.
    struct Handle: Equatable {
        var horizontal: Int
        var vertical: Int
    }

    /// The usual place: centred at the bottom of `screen`, `size` clamped to it.
    static func defaultFrame(size: NSSize = defaultSize, on screen: NSRect) -> NSRect {
        let width = max(min(size.width, screen.width - 32), min(minimumSize.width, screen.width))
        let height = max(min(size.height, screen.height - 48), min(minimumSize.height, screen.height))
        let y = min(screen.minY + bottomInset, screen.maxY - height)
        return NSRect(x: (screen.midX - width / 2).rounded(), y: max(screen.minY, y), width: width, height: height)
    }

    /// The frame kept inside `screen`: no larger than it, every edge on it.
    static func clamped(_ frame: NSRect, to screen: NSRect) -> NSRect {
        let width = min(max(frame.width, min(minimumSize.width, screen.width)), screen.width)
        let height = min(max(frame.height, min(minimumSize.height, screen.height)), screen.height)
        let x = min(max(frame.minX, screen.minX), screen.maxX - width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// The display a frame belongs to: the one holding its centre, otherwise
    /// the one it overlaps most; nil when it is on none of them.
    static func screen(for frame: NSRect, among screens: [NSRect]) -> NSRect? {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        if let holding = screens.first(where: { $0.contains(centre) }) { return holding }
        let overlaps = screens.map { ($0, $0.intersection(frame)) }.filter { !$0.1.isNull && $0.1.width * $0.1.height > 0 }
        return overlaps.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }

    /// Where the overlay opens: the saved frame on its display, kept inside
    /// it; the saved size at the usual place on `fallback` when that display
    /// is gone (or no longer overlaps it); the default frame when nothing was
    /// saved.
    static func restored(saved: NSRect?, screens: [NSRect], fallback: NSRect) -> NSRect {
        guard let saved, saved.width > 0, saved.height > 0, saved.width.isFinite, saved.height.isFinite else {
            return defaultFrame(on: fallback)
        }
        guard let screen = screen(for: saved, among: screens) else {
            return defaultFrame(size: saved.size, on: fallback)
        }
        return clamped(saved, to: screen)
    }

    static func load(from defaults: UserDefaults) -> NSRect? {
        guard let value = defaults.string(forKey: defaultsKey) else { return nil }
        let frame = NSRectFromString(value)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    static func save(_ frame: NSRect, to defaults: UserDefaults) {
        defaults.set(NSStringFromRect(frame.integral), forKey: defaultsKey)
    }

    /// The handle under `point` (window coordinates, origin bottom-left) of a
    /// panel this big: the margin and a `grip` inside the box's edge resize;
    /// near a corner both ways. Nil inside the box, where a press moves it.
    static func handle(at point: NSPoint, in size: NSSize) -> Handle? {
        let box = NSRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let reach = box.insetBy(dx: grip, dy: grip)
        guard NSRect(origin: .zero, size: size).contains(point), !reach.contains(point) else { return nil }
        var horizontal = point.x < reach.minX ? -1 : point.x > reach.maxX ? 1 : 0
        var vertical = point.y < reach.minY ? -1 : point.y > reach.maxY ? 1 : 0
        // Near a corner along one edge: both ways, as a window's corner.
        if horizontal != 0, vertical == 0 {
            if point.y < box.minY + cornerGrip { vertical = -1 } else if point.y > box.maxY - cornerGrip { vertical = 1 }
        } else if vertical != 0, horizontal == 0 {
            if point.x < box.minX + cornerGrip { horizontal = -1 } else if point.x > box.maxX - cornerGrip { horizontal = 1 }
        }
        return Handle(horizontal: horizontal, vertical: vertical)
    }

    /// `start` resized by dragging `handle` by `delta` (screen points, y up):
    /// the opposite edges stay put, the size never goes below `minimumSize`
    /// and the moving edges stop at `screen`'s edges.
    static func resized(_ start: NSRect, handle: Handle, by delta: CGVector, within screen: NSRect) -> NSRect {
        var frame = start
        let minimumWidth = min(minimumSize.width, start.width)
        let minimumHeight = min(minimumSize.height, start.height)
        switch handle.horizontal {
        case 1:
            frame.size.width = min(max(start.width + delta.dx, minimumWidth), max(minimumWidth, screen.maxX - start.minX))
        case -1:
            frame.size.width = min(max(start.width - delta.dx, minimumWidth), max(minimumWidth, start.maxX - screen.minX))
            frame.origin.x = start.maxX - frame.width
        default: break
        }
        switch handle.vertical {
        case 1:
            frame.size.height = min(max(start.height + delta.dy, minimumHeight), max(minimumHeight, screen.maxY - start.minY))
        case -1:
            frame.size.height = min(max(start.height - delta.dy, minimumHeight), max(minimumHeight, start.maxY - screen.minY))
            frame.origin.y = start.maxY - frame.height
        default: break
        }
        return frame
    }

    /// `start` moved by `delta`, kept on the display the pointer is on.
    static func moved(_ start: NSRect, by delta: CGVector, within screen: NSRect) -> NSRect {
        clamped(start.offsetBy(dx: delta.dx, dy: delta.dy), to: screen)
    }

    /// The cursor that says what a press there does.
    static func cursor(for handle: Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (handle.horizontal, handle.vertical) {
            case (-1, 1): position = .topLeft
            case (1, 1): position = .topRight
            case (-1, -1): position = .bottomLeft
            case (1, -1): position = .bottomRight
            case (-1, _): position = .left
            case (1, _): position = .right
            case (_, 1): position = .top
            default: position = .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return handle.horizontal != 0 && handle.vertical == 0 ? .resizeLeftRight
            : handle.horizontal == 0 ? .resizeUpDown : .crosshair
    }
}

/// Moves and resizes the subtitle overlay from the panel's own events: the
/// overlay floats over a video in another app, its panel is never key, and a
/// SwiftUI drag would lose the first press there (the same bridge that drops
/// × clicks, docs/bugs/2026-09-04-island-answer-close-first-mouse.md). The
/// window always gets the event. A press on a control (the language menus,
/// Stop, ×, a fix button) is left to the control.
// WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
@MainActor
final class SubtitleOverlayFrameTracker: NSResponder {
    /// Only the subtitle overlay moves this way; the text palette keeps
    /// AppKit's own behaviour.
    var isEnabled = false {
        didSet { if !isEnabled { cancel() } }
    }
    /// Where controls are, so a press there is theirs.
    weak var hitTargets: SubtitleOverlayHitTargets?
    /// The visible frames of the displays, and the one under a point.
    var screens: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
    /// A move or resize ended: the frame to remember.
    var didFinish: (NSRect) -> Void = { _ in }

    private enum Drag { case move, resize(SubtitleOverlayFrame.Handle) }
    private var drag: Drag?
    private var startFrame = NSRect.zero
    private var startPoint = NSPoint.zero
    private var showsResizeCursor = false

    /// True while a move or resize is in progress.
    var isTracking: Bool { drag != nil }

    func cancel() { drag = nil }

    /// Handles a mouse event aimed at the overlay's frame; true when consumed.
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard isEnabled else { return false }
        switch event.type {
        case .leftMouseDown:
            drag = nil
            guard !event.modifierFlags.contains(.control) else { return false }
            let point = event.locationInWindow
            if let handle = SubtitleOverlayFrame.handle(at: point, in: window.frame.size) {
                drag = .resize(handle)
            } else if hitTargets?.isControl(at: point, in: window) == true {
                return false
            } else {
                drag = .move
            }
            startFrame = window.frame
            startPoint = window.convertPoint(toScreen: point)
            return true
        case .leftMouseDragged:
            guard let drag else { return false }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let delta = CGVector(dx: point.x - startPoint.x, dy: point.y - startPoint.y)
            let screens = screens()
            let frame: NSRect
            switch drag {
            case .move:
                let screen = screens.first { $0.contains(point) }
                    ?? SubtitleOverlayFrame.screen(for: startFrame, among: screens) ?? startFrame
                frame = SubtitleOverlayFrame.moved(startFrame, by: delta, within: screen)
            case .resize(let handle):
                let screen = SubtitleOverlayFrame.screen(for: startFrame, among: screens) ?? startFrame.union(window.frame)
                frame = SubtitleOverlayFrame.resized(startFrame, handle: handle, by: delta, within: screen)
            }
            if frame != window.frame { window.setFrame(frame, display: true) }
            return true
        case .leftMouseUp:
            guard drag != nil else { return false }
            drag = nil
            if window.frame != startFrame { didFinish(window.frame) }
            return true
        default:
            return false
        }
    }

    // MARK: Cursor (a tracking area on the content view, active while inactive)

    func install(on view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(event) }

    override func mouseExited(with event: NSEvent) {
        if showsResizeCursor, drag == nil { NSCursor.arrow.set() }
        showsResizeCursor = false
    }

    private func updateCursor(_ event: NSEvent) {
        guard isEnabled, drag == nil, let window = event.window else { return }
        if let handle = SubtitleOverlayFrame.handle(at: event.locationInWindow, in: window.frame.size) {
            SubtitleOverlayFrame.cursor(for: handle).set()
            showsResizeCursor = true
        } else if showsResizeCursor {
            NSCursor.arrow.set()
            showsResizeCursor = false
        }
    }
}
