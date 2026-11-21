import AppKit
import Foundation

/// A finger on a touch display (macOS 27) has no hover and sends no
/// `mouseMoved` before a tap (Apple: "Adopting gesture recognizers in your
/// app", TN3216). The island window claims mouse events only where the
/// pointer already is, so a tap on the island fell through to the app
/// underneath. On a touch-capable screen transparent target windows cover
/// each visible island surface while the island window ignores the mouse; a
/// tap there starts a touch session in which the island window takes every
/// event in its frame until the session ends.
/// WHY: .project-docs/decisions/2026-11-22-island-touch-tap.md
struct IslandTouchSession: Equatable {
    /// No touch inside the island for this long ends the session (a finger
    /// has no pointer exit to close a drawer it opened).
    static let idleTimeout: TimeInterval = 8

    private(set) var isActive = false
    /// The session opened the drawer itself, so ending it closes the drawer.
    private(set) var openedDrawer = false
    private(set) var lastTouch: TimeInterval = 0

    mutating func begin(at now: TimeInterval, openedDrawer: Bool) {
        isActive = true
        self.openedDrawer = self.openedDrawer || openedDrawer
        lastTouch = now
    }

    mutating func noteTouch(at now: TimeInterval) {
        guard isActive else { return }
        lastTouch = now
    }

    func hasExpired(now: TimeInterval) -> Bool {
        isActive && now - lastTouch >= Self.idleTimeout
    }

    /// Ends the session; returns whether the drawer it opened must close.
    @discardableResult
    mutating func end() -> Bool {
        let closeDrawer = isActive && openedDrawer
        self = IslandTouchSession()
        return closeDrawer
    }
}

enum IslandTouchRouting {
    enum TapAction: Equatable {
        /// The compact capsule hides its tools and Update buttons until
        /// hovered; a tap reveals them the way hovering does.
        case openDrawer
        /// Any other surface already shows its controls: deliver the tap.
        case deliver
    }

    /// While a touch session runs the island window takes every event in its
    /// frame; otherwise the pointer decides exactly as before.
    static func shouldIgnoreMouseEvents(pointerDecision: Bool, sessionActive: Bool) -> Bool {
        sessionActive ? false : pointerDecision
    }

    /// Rects the touch targets cover: every visible island surface while the
    /// island window ignores the mouse on a touch-capable screen. Nothing on
    /// any other screen, so a Mac without touch never gets a target window.
    static func targetFrames(
        touchCapable: Bool,
        shown: Bool,
        sessionActive: Bool,
        islandIgnoresMouse: Bool,
        idleHidden: Bool,
        compactFrame: NSRect,
        agentSurfaceFrames: [NSRect]
    ) -> [NSRect] {
        guard touchCapable, shown, !sessionActive, islandIgnoresMouse else { return [] }
        // An idle-hidden capsule is invisible: a target there would eat taps
        // on whatever is under it.
        var frames = idleHidden ? [] : [compactFrame]
        frames += agentSurfaceFrames.filter { !$0.isEmpty }
        return frames
    }

    static func action(for point: NSPoint, compactFrame: NSRect, drawerExpanded: Bool) -> TapAction {
        compactFrame.contains(point) && !drawerExpanded ? .openDrawer : .deliver
    }

    /// A tap during the session over none of the rendered surfaces lands on
    /// the island window's transparent area: it ends the session, the way a
    /// tap outside an open menu closes it.
    static func endsSession(tapAt point: NSPoint, activeFrames: [NSRect]) -> Bool {
        !activeFrames.contains { $0.contains(point) }
    }
}

/// Transparent windows over the island's visible surfaces on a touch screen.
/// Each takes the tap (AppKit emulates mouseDown/mouseUp for a finger on a
/// view that overrides mouseDown) and reports its screen point.
@MainActor
final class IslandTouchTargets {
    private(set) var panels: [IslandTouchTargetPanel] = []
    private let presentsWindows: Bool
    var onTap: (NSPoint) -> Void = { _ in }
    /// The pointer (trackpad or mouse) reached a target: the island must take
    /// over at once, or the target would hide the island's hover from it.
    var onPointer: () -> Void = {}

    /// `presentsWindows` is false in tests: the panels exist and receive
    /// events but are never ordered on screen.
    init(presentsWindows: Bool = true) {
        self.presentsWindows = presentsWindows
    }

    /// Frames of the targets currently taking taps.
    var activeFrames: [NSRect] { panels.filter(\.isActiveTarget).map(\.frame) }

    func update(frames: [NSRect], level: NSWindow.Level, sharingType: NSWindow.SharingType) {
        while panels.count < frames.count {
            let panel = IslandTouchTargetPanel()
            panel.onTap = { [weak self] point in self?.onTap(point) }
            panel.onPointer = { [weak self] in self?.onPointer() }
            panels.append(panel)
        }
        for (index, panel) in panels.enumerated() {
            guard index < frames.count else {
                panel.isActiveTarget = false
                if panel.isVisible { panel.orderOut(nil) }
                continue
            }
            panel.isActiveTarget = true
            panel.level = level
            panel.sharingType = sharingType
            if panel.frame != frames[index] {
                panel.setFrame(frames[index], display: false)
            }
            if presentsWindows, !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    func removeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

final class IslandTouchTargetPanel: NSPanel {
    var onTap: (NSPoint) -> Void = { _ in }
    var onPointer: () -> Void = {}
    /// A retired target never reports a tap.
    var isActiveTarget = false

    init() {
        super.init(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = IslandTouchTargetView()
        view.onDown = { [weak self] event in self?.report(event) }
        view.onPointer = { [weak self] in
            guard let self, self.isActiveTarget else { return }
            self.onPointer()
        }
        contentView = view
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func report(_ event: NSEvent) {
        guard isActiveTarget else { return }
        onTap(convertPoint(toScreen: event.locationInWindow))
    }
}

final class IslandTouchTargetView: NSView {
    var onDown: (NSEvent) -> Void = { _ in }
    /// Pointer-only: a finger has no hover, so these never fire for touch.
    var onPointer: () -> Void = {}
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointer() }
    override func mouseMoved(with event: NSEvent) { onPointer() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Overriding mouseDown is what makes AppKit emulate a finger tap as a
    /// click here.
    override func mouseDown(with event: NSEvent) { onDown(event) }
    override func mouseUp(with event: NSEvent) {}
    /// A long press arrives as a right click; the island has no context menu.
    override func rightMouseDown(with event: NSEvent) {}
}
