import AppKit
import Combine
import Foundation
import SwiftUI

/// Which Costs row shows its "Models used" detail. One state for the whole
/// table and the only source of truth: AppKit never closes the detail on its
/// own (see `AIUsageModelsHoverController`).
///
/// Ownership is either the pointer or the keyboard. The pointer owns by
/// default: the detail and the fill belong to the row under it. Focus (Tab)
/// or keyboard activation gives ownership to that row; only real pointer
/// motion (a changed screen point) takes it back. Re-reading a resting
/// pointer (poll, scroll, layout) never changes ownership.
///
/// WHY: .project-docs/decisions/2026-11-26-costs-models-popover-hover.md
struct AIUsageModelsHoverState: Equatable {
    /// Entering the table from outside opens after this delay, so passing
    /// over it opens nothing. With a detail open, switching rows is immediate.
    static let openDelay: TimeInterval = 0.2

    /// Where the pointer is, resolved from geometry by the controller.
    enum Pointer: Equatable {
        case outside
        case row(String)
        /// On the open detail, which may cover other rows.
        case detail
    }

    enum Event: Equatable {
        /// The pointer's location re-read without the pointer moving.
        case pointer(Pointer)
        /// The pointer itself moved (any changed screen point).
        case pointerMoved(Pointer)
        case focused(String)
        case unfocused(String)
        /// Click on a row, or Return/Space on its focused name.
        case clicked(String)
        case escape
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

    private(set) var open: String?
    private(set) var pointer: Pointer = .outside
    /// Non-nil while the keyboard owns the detail; always equals `open` then.
    private(set) var keyboardRow: String?
    private(set) var pending: Pending?
    /// Escape or a click closed this row's detail with the pointer on it; it
    /// stays closed until the pointer leaves the row.
    private(set) var suppressedRow: String?

    var pointerRow: String? { if case .row(let id) = pointer { return id } else { return nil } }

    /// The row painted with the hover fill: the owner's row.
    func highlighted(_ id: String) -> Bool {
        if let row = keyboardRow { return row == id }
        switch pointer {
        case .row(let row): return row == id
        case .detail: return open == id
        case .outside: return false
        }
    }

    mutating func send(_ event: Event, now: Date) {
        switch event {
        case .pointer(let location):
            if keyboardRow != nil {
                // A resting pointer never takes the keyboard's detail.
                record(location)
            } else {
                followPointer(to: location, now: now, force: false)
            }
        case .pointerMoved(let location):
            let handover = keyboardRow != nil
            keyboardRow = nil
            followPointer(to: location, now: now, force: handover)
        case .focused(let id):
            keyboardRow = id; open = id; pending = nil; suppressedRow = nil
        case .unfocused(let id):
            guard keyboardRow == id else { return }
            // Focus left for something that is not a model row: the pointer
            // owns again, wherever it rests.
            keyboardRow = nil
            followPointer(to: pointer, now: now, force: true)
        case .clicked(let id):
            pending = nil
            if open == id {
                open = nil; keyboardRow = nil
                suppressedRow = pointerRow == id ? id : nil
            } else {
                open = id; suppressedRow = nil
                // A click on the row under the pointer belongs to the
                // pointer; activation elsewhere (Return) to the keyboard.
                keyboardRow = pointerRow == id ? nil : id
            }
        case .escape:
            open = nil; keyboardRow = nil; pending = nil
            suppressedRow = pointerRow
            if pointer == .detail { pointer = .outside }
        case .disabled:
            self = Self()
        case .rowsChanged(let ids):
            let shown = Set(ids)
            if let id = open, !shown.contains(id) { open = nil; keyboardRow = nil; pending = nil }
            if let id = pointerRow, !shown.contains(id) { pointer = .outside }
            if open == nil, pointer == .detail { pointer = .outside }
            if let target = pending?.target, !shown.contains(target) { pending = nil }
            if let id = suppressedRow, !shown.contains(id) { suppressedRow = nil }
        case .tick:
            guard let due = pending, now >= due.at else { return }
            pending = nil
            if keyboardRow == nil, pointerRow == due.target { open = due.target }
        }
    }

    private mutating func record(_ location: Pointer) {
        pointer = (location == .detail && open == nil) ? .outside : location
    }

    /// Pointer ownership: the detail and fill belong to the row under it.
    /// `force` re-applies an unchanged location (ownership just returned).
    private mutating func followPointer(to location: Pointer, now: Date, force: Bool) {
        guard force || location != pointer else { return }
        let previous = pointer
        record(location)
        switch pointer {
        case .detail:
            pending = nil
        case .row(let id):
            if let row = suppressedRow, row != id { suppressedRow = nil }
            if suppressedRow == id { pending = nil; return }
            if open == id {
                pending = nil
            } else if open != nil || previous == .detail {
                // A detail is showing: follow the pointer at once and never
                // leave another row's detail on screen.
                open = id; pending = nil
            } else if pending?.target != id {
                pending = Pending(target: id, at: now.addingTimeInterval(Self.openDelay))
            }
        case .outside:
            open = nil; pending = nil; suppressedRow = nil
        }
    }
}

/// Resolves the pointer from geometry, drives `AIUsageModelsHoverState` and
/// presents the one detail popover.
///
/// The popover is an `NSPopover` with `.applicationDefined` behavior owned
/// here: AppKit never closes it, so no asynchronous native dismissal can
/// close a newer detail (builder findings on queue tickets 693, 701 and 711
/// against SwiftUI's transient `.popover`). It opens, moves and closes only
/// from the state.
///
/// Row and name frames come from SwiftUI (`onGeometryChange` in the table's
/// named coordinate space) and map to the screen through one anchor NSView
/// placed outside the ScrollView: NSViews inside SwiftUI's ScrollView report
/// the whole window as their frame. Mouse events, hover callbacks and a short
/// poll only trigger a fresh resolution; a changed screen point is motion.
@MainActor
final class AIUsageModelsHoverController: ObservableObject {
    static let coordinateSpace = "AIUsageCostsTable"
    /// AppKit must never close the detail on its own (see type comment).
    static let popoverBehavior: NSPopover.Behavior = .applicationDefined

    @Published private(set) var state = AIUsageModelsHoverState()
    private let now: () -> Date
    private let mouseLocation: () -> NSPoint
    private let topWindowNumber: (NSPoint) -> Int
    private var rowFrames: [String: CGRect] = [:]
    private var nameFrames: [String: CGRect] = [:]
    private var rows: [String: AIUsageCostRow] = [:]
    private var rowOrder: [String] = []
    private weak var anchor: NSView?
    private var lastPoint: NSPoint?
    private(set) var isEnabled = true

    /// Tests stand in for the popover window, which they cannot show.
    var detailScreenFrameOverride: (() -> NSRect?)?
    /// Tests observe presentation instead of showing an NSPopover.
    var presenter: ((AIUsageCostRow?, NSRect) -> Void)?

    private var popover: NSPopover?
    private var hosting: NSHostingController<AnyView>?
    private var presentedID: String?
    private var timer: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

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
        syncPresentation()
    }

    // MARK: Geometry

    func setAnchor(_ view: NSView) { anchor = view }
    func setRowFrame(_ frame: CGRect, for id: String) { rowFrames[id] = frame; syncPresentation() }
    func setNameFrame(_ frame: CGRect, for id: String) { nameFrames[id] = frame; syncPresentation() }

    /// The rows on screen now (empty while loading, empty or failed). No
    /// open, pending, pointer or focus state may outlive its row.
    func retain(rows visible: [AIUsageCostRow]) {
        rowOrder = visible.map(\.id)
        rows = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        rowFrames = rowFrames.filter { rows[$0.key] != nil }
        nameFrames = nameFrames.filter { rows[$0.key] != nil }
        send(.rowsChanged(rowOrder))
        refreshContent()
    }

    /// Rows by id only (tests).
    func retain(rowIDs ids: [String]) {
        retain(rows: ids.map { AIUsageCostRow(title: $0, events: []) })
    }

    private func local(_ frame: CGRect, in anchor: NSView) -> NSRect {
        NSRect(x: frame.minX, y: anchor.isFlipped ? frame.minY : anchor.bounds.height - frame.maxY,
               width: frame.width, height: frame.height)
    }

    /// A row's visible frame on screen; nil when it is scrolled out of view.
    func screenFrame(of id: String) -> NSRect? {
        guard let frame = rowFrames[id], let anchor, let window = anchor.window else { return nil }
        let visible = local(frame, in: anchor).intersection(anchor.bounds)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return window.convertToScreen(anchor.convert(visible, to: nil))
    }

    func resolve(_ point: NSPoint) -> AIUsageModelsHoverState.Pointer {
        let top = topWindowNumber(point)
        if state.open != nil, let detail = detailScreenFrame(), detail.contains(point),
           detailScreenFrameOverride != nil || top == popover?.contentViewController?.view.window?.windowNumber {
            return .detail
        }
        guard let window = anchor?.window, top == window.windowNumber else { return .outside }
        for id in rowOrder {
            if let frame = screenFrame(of: id), frame.contains(point) { return .row(id) }
        }
        return .outside
    }

    /// Re-reads the pointer. A changed screen point is motion; the first
    /// sample and the same point again (poll, scroll, layout) are re-reads.
    func checkPointer(at point: NSPoint? = nil) {
        let point = point ?? mouseLocation()
        let moved = lastPoint.map { $0 != point } ?? false
        lastPoint = point
        let location = resolve(point)
        send(moved ? .pointerMoved(location) : .pointer(location))
    }

    private func detailScreenFrame() -> NSRect? {
        if let override = detailScreenFrameOverride { return override() }
        guard let window = popover?.contentViewController?.view.window, window.isVisible else { return nil }
        return window.frame
    }

    // MARK: Presentation

    /// The open row's name in anchor coordinates, if it is visible.
    private func anchorRect(for id: String) -> NSRect? {
        guard let anchor, let frame = nameFrames[id] ?? rowFrames[id] else { return nil }
        let rect = local(frame, in: anchor)
        return rect.intersects(anchor.bounds) ? rect : nil
    }

    private func syncPresentation() {
        guard let id = state.open, let row = rows[id], let anchor, let rect = anchorRect(for: id) else {
            presentedID = nil
            if let presenter { presenter(nil, .zero) }
            if popover?.isShown == true { popover?.performClose(nil) }
            return
        }
        if let presenter {
            presentedID = id
            presenter(row, rect)
            return
        }
        guard let window = anchor.window, window.isVisible else { return }
        let popover = self.popover ?? makePopover()
        if presentedID != id || hosting?.rootView == nil { hosting?.rootView = content(for: row) }
        presentedID = id
        if popover.isShown {
            if popover.positioningRect != rect { popover.positioningRect = rect }
        } else {
            popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxX)
        }
    }

    /// The real popover, for tests and diagnostics.
    var detailWindowFrame: NSRect? { popover?.isShown == true ? popover?.contentViewController?.view.window?.frame : nil }
    var presentedRowID: String? { popover?.isShown == true ? presentedID : nil }
    /// Where the shown popover points, on screen.
    var presentedAnchorScreenRect: NSRect? {
        guard let popover, popover.isShown, let anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(popover.positioningRect, to: nil))
    }

    private func refreshContent() {
        guard let id = presentedID, let row = rows[id], popover?.isShown == true else { return }
        hosting?.rootView = content(for: row)
    }

    private func content(for row: AIUsageCostRow) -> AnyView {
        AnyView(AIUsageModelsPopover(row: row)
            .onContinuousHover { [weak self] _ in self?.checkPointer() }
            .onExitCommand { [weak self] in self?.send(.escape) })
    }

    private func makePopover() -> NSPopover {
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = Self.popoverBehavior
        popover.animates = true
        popover.contentViewController = hosting
        self.popover = popover; self.hosting = hosting
        return popover
    }

    // MARK: Event sources

    /// Mouse moves anywhere in the app (the Settings window or the detail)
    /// trigger a resolution, including moves that cross between windows.
    func start() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .scrollWheel, .mouseEntered, .mouseExited]) { [weak self] event in
                self?.checkPointer()
                return event
            }
        }
        if resignObserver == nil {
            // A detail must not stay over another app.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.escape) }
            }
        }
    }

    func stop() {
        timer?.cancel(); poll?.cancel(); timer = nil; poll = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        popover?.close()
        presentedID = nil
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
            // Backstop for changes no event reports (content scrolled by
            // keyboard, the pointer leaving to another app).
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
