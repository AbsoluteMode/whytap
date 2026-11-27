import AppKit
import Combine
import Foundation
import SwiftUI

/// Which Costs row shows its "Models used" detail. One state for the whole
/// table, so two rows can never both believe they are open and the detail is
/// always the one anchored to the row it describes.
///
/// WHY: .project-docs/decisions/2026-11-26-costs-models-popover-hover.md —
/// each row used to own its popover; the detail opens beside the name and
/// lands under the pointer, so the row lost hover, closed it and reopened it
/// (flicker), and a closing row and an opening row raced for one window.
struct AIUsageModelsHoverState: Equatable {
    /// From rest the detail waits briefly, so sweeping across rows opens nothing.
    static let openDelay: TimeInterval = 0.2
    /// Leaving the row and the detail closes it after this grace period, long
    /// enough to cross the gap between the row and the detail.
    static let closeGrace: TimeInterval = 0.3
    /// A click on the open row right after the system closed its transient
    /// detail (that same mouse-down) means "close", not "open again".
    static let reopenSuppression: TimeInterval = 0.4

    enum Event: Equatable {
        case pointerEnteredRow(String)
        case pointerExitedRow(String)
        case pointerEnteredDetail
        case pointerExitedDetail
        case focused(String)
        case unfocused(String)
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
        /// nil closes the detail.
        var target: String?
        var at: Date
    }

    private(set) var open: String?
    private(set) var pinned = false
    /// The row under the pointer in the Settings window itself.
    private(set) var pointerRow: String?
    /// The pointer is over the open detail, which may cover other rows.
    private(set) var pointerOnDetail = false
    private(set) var focusedRow: String?
    private(set) var pending: Pending?
    private var lastDismissal: (id: String, at: Date)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.open == rhs.open && lhs.pinned == rhs.pinned && lhs.pointerRow == rhs.pointerRow
            && lhs.pointerOnDetail == rhs.pointerOnDetail && lhs.focusedRow == rhs.focusedRow
            && lhs.pending == rhs.pending && lhs.lastDismissal?.id == rhs.lastDismissal?.id
            && lhs.lastDismissal?.at == rhs.lastDismissal?.at
    }

    /// The row painted with the hover fill: the one under the pointer, or the
    /// open one while the pointer is on its detail.
    func highlighted(_ id: String) -> Bool {
        pointerRow == id || (pointerRow == nil && open == id)
    }

    mutating func send(_ event: Event, now: Date) {
        switch event {
        case .pointerEnteredRow(let id):
            pointerRow = id
            if open == id {
                pending = nil
            } else if pinned {
                // A pinned detail stays until a click, Escape or a click outside.
                pending = nil
            } else if open != nil {
                // Warm: another detail is already showing, so follow the pointer
                // at once instead of leaving the wrong row's detail on screen.
                open = id; pending = nil
            } else {
                pending = Pending(target: id, at: now.addingTimeInterval(Self.openDelay))
            }
        case .pointerExitedRow(let id):
            // Enter of the next row can arrive before exit of the previous one.
            if pointerRow == id { pointerRow = nil }
            if pending?.target == id { pending = nil }
            scheduleCloseIfUnheld(now: now)
        case .pointerEnteredDetail:
            // The pointer is in the detail's window, so on no row of Settings.
            pointerOnDetail = true; pointerRow = nil
            pending = nil
        case .pointerExitedDetail:
            pointerOnDetail = false
            if let row = pointerRow, row != open, !pinned {
                open = row; pending = nil
            } else {
                scheduleCloseIfUnheld(now: now)
            }
        case .focused(let id):
            focusedRow = id
            if !(pinned && open != id) { open = id; pending = nil }
        case .unfocused(let id):
            if focusedRow == id { focusedRow = nil }
            scheduleCloseIfUnheld(now: now)
        case .clicked(let id):
            pending = nil
            if open == id && pinned {
                close()
            } else if open == nil, let last = lastDismissal, last.id == id,
                      now.timeIntervalSince(last.at) < Self.reopenSuppression {
                lastDismissal = nil
            } else {
                open = id; pinned = true
            }
        case .escape:
            close()
        case .dismissedBySystem(let id):
            guard open == id else { return }
            lastDismissal = pinned ? (id, now) : nil
            close()
            // A transient detail closes on a click outside it; the pointer
            // may still rest on a row, which must not reopen it by itself.
        case .disabled:
            self = Self()
        case .rowsChanged(let ids):
            let shown = Set(ids)
            if let id = open, !shown.contains(id) { close() }
            if let id = pointerRow, !shown.contains(id) { pointerRow = nil }
            if let id = focusedRow, !shown.contains(id) { focusedRow = nil }
            if let target = pending?.target, !shown.contains(target) { pending = nil }
            if let last = lastDismissal, !shown.contains(last.id) { lastDismissal = nil }
            if shown.isEmpty { pointerOnDetail = false }
        case .tick:
            guard let due = pending, now >= due.at else { return }
            pending = nil
            if let target = due.target {
                if pointerRow == target || focusedRow == target { open = target }
            } else if !held {
                close()
            }
        }
    }

    private var held: Bool {
        pinned || pointerOnDetail || (open != nil && (pointerRow == open || focusedRow == open))
    }

    private mutating func scheduleCloseIfUnheld(now: Date) {
        guard open != nil, !held else { return }
        if let row = pointerRow, row != open {
            // The pointer already rests on another row: show that one.
            open = row; pending = nil
            return
        }
        pending = Pending(target: nil, at: now.addingTimeInterval(Self.closeGrace))
    }

    private mutating func close() {
        open = nil; pinned = false; pending = nil; pointerOnDetail = false
    }
}

/// Drives `AIUsageModelsHoverState` with real time and the real pointer.
/// SwiftUI hover is tracked per window: a detail appearing under a resting
/// pointer gets no "entered" until the pointer leaves and returns, and rows
/// it covers keep stale hover. So while a detail is open the controller also
/// reads which window is topmost under the pointer and which row's visible
/// frame contains it, and turns differences into the same events.
@MainActor
final class AIUsageModelsHoverController: ObservableObject {
    struct PointerProbe { var row: String?; var onDetail: Bool }

    @Published private(set) var state = AIUsageModelsHoverState()
    private let now: () -> Date
    private var probeOverride: (() -> PointerProbe)?
    private var timer: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var rowViews: [String: WeakView] = [:]
    private weak var detailView: NSView?
    private struct WeakView { weak var view: NSView? }

    init(now: @escaping () -> Date = Date.init, probe: (() -> PointerProbe)? = nil) {
        self.now = now; self.probeOverride = probe
    }

    func isPresented(_ id: String) -> Bool { state.open == id }

    func send(_ event: AIUsageModelsHoverState.Event) {
        var next = state
        next.send(event, now: now())
        if next != state { state = next }
        reschedule()
    }

    /// A period change can remove rows or the whole table (loading, empty,
    /// error); no open, pending, pointer or focus state may outlive its row.
    func retain(rows ids: [String]) {
        send(.rowsChanged(ids))
        rowViews = rowViews.filter { ids.contains($0.key) }
    }

    func register(row id: String, view: NSView) { rowViews[id] = WeakView(view: view) }
    func registerDetail(_ view: NSView) { detailView = view }

    /// Reconciles hover with the pointer's actual position (see type comment).
    func checkPointer() {
        guard state.open != nil, let probe = probeOverride?() ?? liveProbe() else { return }
        if probe.row != state.pointerRow {
            if let old = state.pointerRow { send(.pointerExitedRow(old)) }
            if let new = probe.row { send(.pointerEnteredRow(new)) }
        }
        if probe.onDetail != state.pointerOnDetail {
            send(probe.onDetail ? .pointerEnteredDetail : .pointerExitedDetail)
        }
    }

    func stop() {
        timer?.cancel(); poll?.cancel(); timer = nil; poll = nil
    }

    private func liveProbe() -> PointerProbe? {
        let point = NSEvent.mouseLocation
        let top = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if let detail = detailView?.window, detail.isVisible, detail.windowNumber == top {
            return PointerProbe(row: nil, onDetail: true)
        }
        let row = rowViews.first { _, box in
            guard let view = box.view, let window = view.window, window.windowNumber == top else { return false }
            let visible = view.visibleRect
            guard !visible.isEmpty else { return false }
            return window.convertToScreen(view.convert(visible, to: nil)).contains(point)
        }?.key
        return PointerProbe(row: row, onDetail: false)
    }

    private func reschedule() {
        timer?.cancel(); timer = nil
        if let due = state.pending {
            let delay = max(0, due.at.timeIntervalSince(now()))
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 1))
                guard !Task.isCancelled, let self else { return }
                if due.target == nil { self.checkPointer() }
                self.send(.tick)
            }
        }
        if state.open == nil {
            poll?.cancel(); poll = nil
        } else if poll == nil {
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.checkPointer()
                }
            }
        }
    }
}

/// A background AppKit view that tells the controller where a row or the open
/// detail is on screen. It never takes hits or draws.
struct AIUsageHoverProbeView: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = ProbeNSView(); register(view); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { register(nsView) }
    private final class ProbeNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
