import AppKit
import Combine
import Foundation
import SwiftUI

/// Which Costs row shows its "Models used" detail. One state for the whole
/// table: the detail and the row fill belong to the row under the pointer.
///
/// WHY: .project-docs/decisions/2026-11-26-costs-models-popover-hover.md —
/// per-row popover state blinked and showed another row's models (first
/// report); the next version located the pointer with NSView frames that
/// SwiftUI's ScrollView reports as the whole window, so every row matched
/// and an arbitrary one (Meetings while the pointer was on Drop Fast) stayed
/// open (second report, 2026-11-27).
struct AIUsageModelsHoverState: Equatable {
    /// Entering the table from outside waits briefly, so passing over it
    /// opens nothing. With a detail open, moving to another row is immediate.
    static let openDelay: TimeInterval = 0.2
    /// A click on a row right after the system closed that row's detail on
    /// the same mouse-down means "close", not "open again".
    static let reopenSuppression: TimeInterval = 0.4

    /// Where the pointer is, resolved from geometry by the controller.
    enum Pointer: Equatable {
        case outside
        case row(String)
        /// On the open detail's window, which may cover other rows.
        case detail
    }

    enum Event: Equatable {
        case pointer(Pointer)
        case focused(String)
        case unfocused(String)
        /// Click on a row or Return/Space on its focused name: open it now.
        case clicked(String)
        case escape
        case dismissedBySystem(String)
        case disabled
        /// The table now shows exactly these rows (empty while loading,
        /// empty or failed). Anything that refers to another row is retired.
        case rowsChanged([String])
        case tick
    }

    struct Pending: Equatable {
        var target: String
        var at: Date
    }

    struct Dismissal: Equatable {
        var row: String
        var at: Date
    }

    private(set) var open: String?
    private(set) var pointer: Pointer = .outside
    /// The row opened from the keyboard; a pointer move over the table replaces it.
    private(set) var keyboardRow: String?
    private(set) var pending: Pending?
    /// Escape or a click outside closed this row's detail while the pointer
    /// stayed on it; it reopens after the pointer leaves the row, or on click.
    private(set) var dismissed: Dismissal?

    var pointerRow: String? { if case .row(let id) = pointer { return id } else { return nil } }

    /// The row painted with the hover fill: the keyboard's row while focus
    /// owns the detail, otherwise the row under the pointer.
    func highlighted(_ id: String) -> Bool {
        if let row = keyboardRow { return open == row && row == id }
        switch pointer {
        case .row(let row): return row == id
        case .detail: return open == id
        case .outside: return open == id && keyboardRow == id
        }
    }

    mutating func send(_ event: Event, now: Date) {
        switch event {
        case .pointer(let location):
            guard location != pointer else { return }
            let previous = pointer
            pointer = location
            switch location {
            case .detail:
                // Only an open detail can be under the pointer.
                if open == nil { pointer = .outside }
                pending = nil
            case .row(let id):
                keyboardRow = nil
                if let gone = dismissed, gone.row != id { dismissed = nil }
                if dismissed != nil { pending = nil; return }
                if open == id {
                    pending = nil
                } else if open != nil || previous == .detail {
                    // A detail is showing: follow the pointer at once and
                    // never leave the previous row's detail on screen.
                    open = id; pending = nil
                } else {
                    pending = Pending(target: id, at: now.addingTimeInterval(Self.openDelay))
                }
            case .outside:
                // Off the open row and off its detail: close now.
                dismissed = nil; pending = nil; keyboardRow = nil; open = nil
            }
        case .focused(let id):
            // Focus shows its row's detail even while the pointer rests on
            // another row; the next pointer move hands it back to the pointer.
            keyboardRow = id; open = id; pending = nil; dismissed = nil
            if pointer == .detail { pointer = .outside }
        case .unfocused(let id):
            if keyboardRow == id {
                keyboardRow = nil
                if open == id, pointer == .outside { open = nil }
            }
        case .clicked(let id):
            pending = nil
            if let gone = dismissed, gone.row == id, now.timeIntervalSince(gone.at) < Self.reopenSuppression {
                // The native popover already closed on this click's mouse-down;
                // consume that dismissal once and stay closed.
                dismissed = Dismissal(row: id, at: .distantPast)
                return
            }
            if open == id {
                // Activating the open row closes it, whether or not the host
                // reports a dismissal (keyboard activation, repeated click).
                // A dismissal that arrives afterwards is ignored: open is nil.
                close()
                dismissed = Dismissal(row: pointerRow ?? id, at: .distantPast)
                return
            }
            dismissed = nil
            open = id
            if pointer == .outside { keyboardRow = id }
        case .escape:
            dismissed = pointerRow.map { Dismissal(row: $0, at: .distantPast) }
            close()
        case .dismissedBySystem(let id):
            guard open == id else { return }
            dismissed = Dismissal(row: pointerRow ?? id, at: now)
            close()
        case .disabled:
            self = Self()
        case .rowsChanged(let ids):
            let shown = Set(ids)
            if let id = open, !shown.contains(id) { close() }
            if let id = pointerRow, !shown.contains(id) { pointer = .outside }
            if open == nil, pointer == .detail { pointer = .outside }
            if let id = keyboardRow, !shown.contains(id) { keyboardRow = nil }
            if let target = pending?.target, !shown.contains(target) { pending = nil }
            if let gone = dismissed, !shown.contains(gone.row) { dismissed = nil }
        case .tick:
            guard let due = pending, now >= due.at else { return }
            pending = nil
            if pointerRow == due.target { open = due.target }
        }
    }

    private mutating func close() {
        open = nil; pending = nil; keyboardRow = nil
        if pointer == .detail { pointer = .outside }
    }
}

/// Resolves the pointer from geometry and drives `AIUsageModelsHoverState`.
///
/// Row frames come from SwiftUI (`onGeometryChange` in the table's named
/// coordinate space) and are mapped to the screen through one anchor NSView
/// placed outside the ScrollView. NSViews inside SwiftUI's ScrollView report
/// the whole window as their frame, so they are never used for geometry.
/// Hover callbacks, mouse events and a short poll while a detail is open or
/// pending only trigger a fresh resolution; none of them is trusted for
/// where the pointer is.
@MainActor
final class AIUsageModelsHoverController: ObservableObject {
    static let coordinateSpace = "AIUsageCostsTable"

    @Published private(set) var state = AIUsageModelsHoverState()
    private let now: () -> Date
    private let mouseLocation: () -> NSPoint
    private let topWindowNumber: (NSPoint) -> Int
    private var rowFrames: [String: CGRect] = [:]
    private var rowOrder: [String] = []
    private weak var anchor: NSView?
    private weak var detailView: NSView?
    /// Tests stand in for the popover window, which they cannot show.
    var detailScreenFrameOverride: (() -> NSRect?)?
    private var timer: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var monitor: Any?
    /// The Costs view's actual enabled state. A disabled table resolves
    /// nothing, so no event source can open a detail behind it.
    private(set) var isEnabled = true

    init(now: @escaping () -> Date = Date.init,
         mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         topWindowNumber: @escaping (NSPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }) {
        self.now = now; self.mouseLocation = mouseLocation; self.topWindowNumber = topWindowNumber
    }

    func isPresented(_ id: String) -> Bool { state.open == id }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { send(.disabled) }
    }

    func send(_ event: AIUsageModelsHoverState.Event) {
        if !isEnabled {
            // Only retiring state passes while the table is disabled.
            switch event {
            case .disabled, .rowsChanged: break
            default: return
            }
        }
        var next = state
        next.send(event, now: now())
        if next != state { state = next }
        reschedule()
    }

    // MARK: Geometry

    func setAnchor(_ view: NSView) { anchor = view }
    var anchorView: NSView? { anchor }
    func registerDetail(_ view: NSView) { detailView = view }
    func setRowFrame(_ frame: CGRect, for id: String) { rowFrames[id] = frame }

    /// A period change can remove rows or the whole table (loading, empty,
    /// error); no open, pending, pointer or focus state may outlive its row.
    func retain(rows ids: [String]) {
        rowOrder = ids
        rowFrames = rowFrames.filter { ids.contains($0.key) }
        send(.rowsChanged(ids))
    }

    /// A row's visible frame on screen; nil when it is scrolled out of view.
    func screenFrame(of id: String) -> NSRect? {
        guard let frame = rowFrames[id], let anchor, let window = anchor.window else { return nil }
        let local = NSRect(x: frame.minX, y: anchor.isFlipped ? frame.minY : anchor.bounds.height - frame.maxY,
                           width: frame.width, height: frame.height)
        let visible = local.intersection(anchor.bounds)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return window.convertToScreen(anchor.convert(visible, to: nil))
    }

    func resolve(_ point: NSPoint) -> AIUsageModelsHoverState.Pointer {
        let top = topWindowNumber(point)
        if state.open != nil, let detail = detailScreenFrame(), detail.contains(point),
           detailScreenFrameOverride != nil || top == detailView?.window?.windowNumber {
            return .detail
        }
        guard let window = anchor?.window, top == window.windowNumber else { return .outside }
        for id in rowOrder {
            if let frame = screenFrame(of: id), frame.contains(point) { return .row(id) }
        }
        return .outside
    }

    /// Re-reads the pointer and applies any change.
    func checkPointer(at point: NSPoint? = nil) {
        send(.pointer(resolve(point ?? mouseLocation())))
    }

    private func detailScreenFrame() -> NSRect? {
        if let override = detailScreenFrameOverride { return override() }
        guard let window = detailView?.window, window.isVisible else { return nil }
        return window.frame
    }

    // MARK: Event sources

    /// Mouse moves anywhere in the app (the Settings window or the detail)
    /// trigger a resolution, including moves that cross between windows.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .scrollWheel, .mouseEntered, .mouseExited]) { [weak self] event in
            self?.checkPointer()
            return event
        }
    }

    func stop() {
        timer?.cancel(); poll?.cancel(); timer = nil; poll = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func reschedule() {
        timer?.cancel(); timer = nil
        if let due = state.pending {
            let delay = max(0, due.at.timeIntervalSince(now()))
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 1))
                guard !Task.isCancelled, let self else { return }
                self.checkPointer()
                self.send(.tick)
            }
        }
        if state.open == nil && state.pending == nil {
            poll?.cancel(); poll = nil
        } else if poll == nil {
            // Backstop for moves no event reports (a window appearing under a
            // resting pointer, scrolling by keyboard).
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, let self else { return }
                    self.checkPointer()
                }
            }
        }
    }
}

/// A background AppKit view that gives the controller a window and a
/// coordinate origin. Use it only outside a ScrollView. It never takes hits.
struct AIUsageHoverAnchorView: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView(); register(view); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { register(nsView) }
    private final class AnchorNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
