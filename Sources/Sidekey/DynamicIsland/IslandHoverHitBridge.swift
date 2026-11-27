import AppKit
import Combine
import SwiftUI

struct IslandHoverHitTargetID: Hashable {
    /// `moreTools` (the More rows) and `moreToggle` (the footer chevron) take
    /// clicks together with `tile`: they are on screen with the grid.
    enum Surface: Hashable { case tile, result, navigation, update, deliveryFailure, agentAnswer, moreTools, moreToggle }
    enum UpdateAction: Hashable { case download, skip, install, later }
    enum DisplayAction: Hashable { case hold }
    enum DeliveryFailureAction: Hashable { case retry, dismiss }
    /// Buttons of a question shown over a panel (Monitor's delete question).
    enum ModalAction: Hashable { case cancel, confirm }
    private enum Control: Hashable {
        case tool(HoverTool), back(String), update(UpdateAction), display(DisplayAction)
        case deliveryFailure(DeliveryFailureAction), tableDisclosure(UUID), modal(ModalAction)
        case moreToolsToggle
    }
    let surface: Surface
    private let control: Control
    var tool: HoverTool? { if case .tool(let tool) = control { return tool }; return nil }

    init(surface: Surface, tool: HoverTool) { self.surface = surface; control = .tool(tool) }
    init(update action: UpdateAction) { surface = .update; control = .update(action) }
    init(deliveryFailure action: DeliveryFailureAction) { surface = .deliveryFailure; control = .deliveryFailure(action) }
    init(tableDisclosure id: UUID) { surface = .agentAnswer; control = .tableDisclosure(id) }
    init(back destination: String) { surface = .navigation; control = .back(destination) }
    init(display action: DisplayAction) { surface = .navigation; control = .display(action) }
    init(modal action: ModalAction) { surface = .navigation; control = .modal(action) }
    /// The footer chevron that shows and hides the More tools section.
    static let moreToolsToggle = IslandHoverHitTargetID(surface: .moreToggle, control: .moreToolsToggle)
    private init(surface: Surface, control: Control) { self.surface = surface; self.control = control }
    /// While a modal question is shown, only its own buttons take clicks.
    var isModal: Bool { if case .modal = control { return true }; return false }
}

struct IslandHoverHitSnapshot: Equatable {
    let owner: UUID
    let id: IslandHoverHitTargetID
    let context: String
    let frame: CGRect
}

enum IslandHoverHitGeometry {
    static func visibleFrame(target: CGRect, visible: CGRect, region: CGRect) -> CGRect? {
        let clipped = target.intersection(visible).intersection(region)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}

/// A press belongs to one measured, unchanged control. Leaving it cancels the
/// activation permanently, but its eventual mouse-up is still consumed.
struct IslandHoverPointerTracking {
    private(set) var captured: IslandHoverHitSnapshot?
    private(set) var consumesSequence = false

    mutating func begin(at point: CGPoint, targets: [IslandHoverHitSnapshot], enabled: Bool) -> Bool {
        captured = nil
        consumesSequence = false
        guard enabled, let target = targets.first(where: { $0.frame.contains(point) }) else { return false }
        captured = target
        consumesSequence = true
        return true
    }

    mutating func move(at point: CGPoint, targets: [IslandHoverHitSnapshot], enabled: Bool) {
        guard let captured else { return }
        if !enabled || !captured.frame.contains(point) || !targets.contains(captured) {
            self.captured = nil
        }
    }

    mutating func end(at point: CGPoint, targets: [IslandHoverHitSnapshot], enabled: Bool) -> UUID? {
        move(at: point, targets: targets, enabled: enabled)
        let owner = captured?.owner
        captured = nil
        consumesSequence = false
        return owner
    }

    mutating func cancel() { captured = nil }
    mutating func discardSequence() { captured = nil; consumesSequence = false }
}

/// A tool lifted by pressing and dragging it in the island's tool grid. The grid's cells
/// stay where they were when the tool was lifted; only which tool sits in
/// which cell changes. The pointer over a cell puts the lifted tool in that
/// cell, so a tile sliding under the pointer never sends it back.
// WHY: .project-docs/decisions/2026-11-25-island-hover-reorder.md
struct IslandHoverReorder: Equatable {
    let tool: HoverTool
    /// The order before the lift, for Escape.
    let original: [HoverTool]
    /// Cell frames in window coordinates by slot index, measured at the lift.
    let cells: [Int: CGRect]
    /// The drawer's frame in window coordinates at the lift. Letting go
    /// outside it takes the tool out of the island.
    var panel: CGRect? = nil

    /// How far past the grid a release still counts as "in the grid" when
    /// the drawer's frame is unknown.
    static let releaseMargin: CGFloat = 24

    /// The slot under the pointer, or nil outside the grid (the tool stays).
    func slot(at point: CGPoint) -> Int? {
        cells.filter { $0.value.contains(point) }.keys.min()
    }

    /// The pointer is outside the hover: letting go here throws the tool
    /// out of the island. Inside the drawer (search, footer, More) a release
    /// keeps it, so dropping back inside is the pointer's way to cancel.
    // WHY: .project-docs/decisions/2026-11-27-hover-drag-out-and-smooth-edits.md
    func removesRelease(at point: CGPoint) -> Bool {
        if let panel, !panel.isNull, !panel.isEmpty { return !panel.contains(point) }
        let grid = cells.values.reduce(CGRect.null) { $0.union($1) }
        guard !grid.isNull else { return false }
        return !grid.insetBy(dx: -Self.releaseMargin, dy: -Self.releaseMargin).contains(point)
    }

    /// The order to put back on cancel, or nil when the layout changed from
    /// elsewhere (Settings Sync, Settings) and the lift no longer describes it.
    func restoredOrder(current: [HoverTool]) -> [HoverTool]? {
        Set(current) == Set(original) && current.count == original.count ? original : nil
    }

    /// Settings is always last and cannot be lifted; a tool that is not in
    /// the island has no cell to leave.
    static func canLift(_ tool: HoverTool?, slots: [HoverTool]) -> Bool {
        guard let tool, tool != .settings, !tool.isComingSoon else { return false }
        return slots.contains(tool)
    }
}

/// Where the lifted tile is drawn: the pointer's travel since the lift, in
/// SwiftUI orientation (y down). Kept apart from the bridge so a pointer move
/// redraws only the floating tile, never the whole island.
// WHY: .project-docs/decisions/2026-11-25-island-hover-reorder.md
@MainActor
final class IslandHoverReorderMotion: ObservableObject {
    @Published private(set) var translation: CGSize = .zero

    func follow(from lift: CGPoint, to point: CGPoint) {
        // Window coordinates grow upward; SwiftUI's grow downward.
        let next = CGSize(width: point.x - lift.x, height: lift.y - point.y)
        if next != translation { translation = next }
    }

    /// The pointer is outside the hover: letting go removes the tool.
    @Published private(set) var outside = false

    func setOutside(_ value: Bool) {
        guard outside != value else { return }
        withAnimation(IslandHoverHitBridge.reducesMotion ? nil : IslandHoverReorderMotionCurve.removeHint) {
            outside = value
        }
    }

    func reset() {
        if translation != .zero { translation = .zero }
        if outside { outside = false }
    }
}

/// The reporters are geometry sources, never mouse catchers. Dispatch remains
/// at NSWindow.sendEvent, the layer that receives first mouse in this overlay.
@MainActor
final class IslandHoverHitBridge: ObservableObject {
    /// The lifted tile's pointer travel; observed only by the floating tile.
    let motion = IslandHoverReorderMotion()
    /// Where the button went down; the lifted tile keeps the same offset from
    /// the pointer it had there.
    private var pressPoint: CGPoint?
    private var liftPoint: CGPoint?
    @Published private(set) var pressedID: IslandHoverHitTargetID?
    /// Where the reorder is, with the lift it belongs to. The island observes
    /// this, not the tool alone: a release and a new lift of the same tile in
    /// one display pass still change the generation, so the new lift gets its
    /// own picture.
    struct ReorderPhase: Equatable {
        /// `removed`: let go outside the hover; the tile vanishes in place.
        enum State: Equatable { case idle, lifted, settling, removed }
        var state: State = .idle
        var tool: HoverTool?
        var generation = 0
    }
    @Published private(set) var reorderPhase = ReorderPhase()
    /// The tool lifted by a press and drag, while it is being moved.
    var reorderingTool: HoverTool? { reorderPhase.state == .lifted ? reorderPhase.tool : nil }
    var isReordering: Bool { reorderingTool != nil }
    /// The tool flying into its cell after a release or cancel, until the
    /// island reports the landing done (`didSettle`) or a fallback ends it.
    var settlingTool: HoverTool? {
        reorderPhase.state == .settling || reorderPhase.state == .removed ? reorderPhase.tool : nil
    }
    /// Counts lifts, so an older landing never ends a newer one.
    var reorderGeneration: Int { reorderPhase.generation }
    /// The drawer stays open through the drag and its landing, while a
    /// tool's context menu is open, and after the island's tools changed
    /// until the person clicks outside or comes back and leaves again.
    var holdsDrawer: Bool { reorderingTool != nil || settlingTool != nil || showsToolMenu || editHold.holdsDrawer }
    /// A tool's context menu (Remove from Hover / Add to Hover) is open.
    @Published private(set) var showsToolMenu = false
    // WHY: .project-docs/decisions/2026-11-26-hover-unpin-and-more-tools.md
    @Published private(set) var editHold = IslandHoverEditHold()
    /// The last hover signal: the pointer over the island or its drawer.
    private(set) var pointerInside = false
    /// The floating tile's picture and place, drawn above the drawer's clip.
    let stage = IslandHoverReorderStage()
    /// The tile pressed at mouse-down that may still become a drag, kept
    /// even after a small move crosses its edge and cancels the click.
    private var dragCandidate: IslandHoverHitSnapshot?
    /// The layout the island shows. Dragging a tile moves tools here,
    /// the same store Settings -> Features -> Hover shows.
    weak var layoutStore: HoverLayoutStore?
    /// How far the pointer moves with the button down before a tile lifts.
    /// Less is a click; this much says the person wants to drag (REV 3).
    static let dragThreshold: CGFloat = 4
    private var reorder: IslandHoverReorder?
    /// Watches the layout while a tool is lifted: a change the drag did not
    /// make (Settings Sync, Settings, the MCP tool) ends the drag as it is.
    private var layoutWatch: AnyCancellable?
    private var writingLayout = false
    private weak var pressWindow: NSWindow?
    private var tracking = IslandHoverPointerTracking()
    private var targets: [UUID: WeakTarget] = [:]
    private var regions: [IslandHoverHitTargetID.Surface: WeakRegion] = [:]
    private var enabled = false
    private var activeSurface: IslandHoverHitTargetID.Surface = .tile
    @Published private(set) var context = ""

    private struct WeakTarget { weak var view: IslandHoverHitTargetView? }
    private struct WeakRegion { weak var view: IslandHoverHitRegionView? }
    private struct WeakModal { weak var view: IslandHoverHitModalView? }
    private var modals: [ObjectIdentifier: WeakModal] = [:]

    var consumesPointerSequence: Bool { tracking.consumesSequence }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        // The drawer closed: nothing is left to hold open.
        if !enabled, !showsToolMenu { editHold.release() }
        if !enabled, tracking.captured?.id.surface != .agentAnswer { cancelPress() }
        // The drawer closed for another reason (an agent, a meeting): the
        // order reached so far is already saved.
        if !enabled { finishReorder() }
    }

    func cancelPress() {
        tracking.cancel()
        dragCandidate = nil
        pressedID = nil
    }
    func cancelPress(for surface: IslandHoverHitTargetID.Surface) {
        if tracking.captured?.id.surface == surface { cancelPress() }
    }

    func discardSequence() {
        tracking.discardSequence()
        dragCandidate = nil
        pressedID = nil
        finishReorder()
    }

    // MARK: - Pin / unpin from the drawer
    // WHY: .project-docs/decisions/2026-11-26-hover-unpin-and-more-tools.md

    /// Takes a tool out of the island; neighbours slide into its place.
    @discardableResult
    func unpin(_ tool: HoverTool) -> Bool {
        guard reorder == nil, let store = layoutStore else { return false }
        var changed = false
        withAnimation(Self.reorderAnimation) { changed = store.unpin(tool) }
        if changed { editHold.edited(pointerInside: pointerInside) }
        return changed
    }

    /// Adds a tool from More at the end of the island, before Settings.
    @discardableResult
    func pin(_ tool: HoverTool) -> Bool {
        guard reorder == nil, let store = layoutStore else { return false }
        var changed = false
        withAnimation(Self.reorderAnimation) { changed = store.pin(tool) }
        if changed { editHold.edited(pointerInside: pointerInside) }
        return changed
    }

    /// The tool a right-click or Control-click at `point` is about: a tile
    /// or a More row. Nothing while a tool is lifted.
    func contextMenuTarget(at point: CGPoint, in window: NSWindow, allowed: Bool) -> IslandHoverHitTargetID? {
        guard reorder == nil, allowed else { return nil }
        // A tool whose own action is off (Calendar shown as Soon) can still be
        // removed: the menu is about its place in Hover, not about opening it.
        return snapshots(in: window, allowsHover: true, allowsAnswer: false, includesInactive: true)
            .first { ($0.id.surface == .tile || $0.id.surface == .moreTools) && $0.frame.contains(point) }?.id
    }

    /// The menu takes the pointer to another window; the drawer must not
    /// read that as the pointer leaving.
    func toolMenuWillOpen() {
        cancelPress()
        showsToolMenu = true
        editHold.edited(pointerInside: pointerInside)
    }

    /// Whatever the menu did, the pointer has not come back yet.
    func toolMenuDidClose() {
        showsToolMenu = false
        editHold.edited(pointerInside: pointerInside)
    }

    /// The pointer is (or is not) over the island and its drawer.
    func notePointer(inside: Bool) {
        pointerInside = inside
        var next = editHold
        next.pointer(inside: inside)
        if next != editHold { editHold = next }
    }

    /// A click outside the drawer or Escape after an edit: end the hold and
    /// ask the island to close the drawer through its explicit dismissal,
    /// even with the pointer still over the pill or the drawer.
    func dismissAfterEdit() {
        // Escape during a drag only cancels that drag (`escapeBelongsToDrag`).
        guard !showsToolMenu, !isReordering, editHold.holdsDrawer else { return }
        editHold.release()
        dismissals.send()
    }

    /// Fires when the drawer must close now (`IslandView.dismissHoverMenu`).
    let dismissals = PassthroughSubject<Void, Never>()

    // MARK: - Press-and-drag reorder

    /// The pressed tile moved far enough to be dragged rather than clicked.
    private func startsDrag(at point: CGPoint) -> Bool {
        guard let pressPoint, dragCandidate != nil else { return false }
        return hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= Self.dragThreshold
    }

    /// Lifts the tile pressed since mouse-down, once the pointer moved
    /// `dragThreshold`; returns false when the press was released, left its
    /// tile or is not a tool that can move. From here on the press never
    /// activates the tool.
    /// The candidate is re-checked against the live, allowed targets: a
    /// window that stopped allowing hover dispatch, or a tile that changed,
    /// never lifts.
    @discardableResult
    func liftPressedTool(allowed: Bool = true) -> Bool {
        guard reorder == nil, allowed, let candidate = dragCandidate,
              let store = layoutStore, IslandHoverReorder.canLift(candidate.id.tool, slots: store.slots),
              let tool = candidate.id.tool, let window = pressWindow else { return false }
        let live = snapshots(in: window, allowsHover: allowed, allowsAnswer: false)
        guard live.contains(where: { $0.owner == candidate.owner && $0.id == candidate.id
            && $0.context == candidate.context }) else { return false }
        var cells: [Int: CGRect] = [:]
        for tile in live where tile.id.surface == .tile && tile.context == candidate.context {
            if let placed = tile.id.tool, let index = store.slots.firstIndex(of: placed) { cells[index] = tile.frame }
        }
        reorder = IslandHoverReorder(tool: tool, original: store.slots, cells: cells, panel: drawerFrame(in: window))
        liftPoint = pressPoint
        motion.reset()
        startEscapeWatch()
        // Settings Sync, Settings or the MCP tool changed the layout: keep
        // theirs. A sync reload counts even when it equals the preview.
        let ended: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.writingLayout else { return }
                self.finishReorder(save: false)
            }
        }
        layoutWatch = store.$slots.dropFirst().map { _ in () }
            .merge(with: store.externalReloads)
            .sink { ended() }
        tracking.cancel()
        dragCandidate = nil
        pressedID = nil
        reorderPhase = ReorderPhase(state: .lifted, tool: tool, generation: reorderPhase.generation + 1)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        return true
    }

    /// The drawer's visible frame in window coordinates (its navigation
    /// region covers the whole drawer).
    private func drawerFrame(in window: NSWindow) -> CGRect? {
        guard let region = regions[.navigation]?.view, region.window === window,
              !region.isHiddenOrHasHiddenAncestor else { return nil }
        let frame = region.convert(region.visibleRect, to: nil)
        return frame.isEmpty ? nil : frame
    }

    /// The lifted tool takes the place of the cell under the pointer at once.
    /// Outside the hover the tile shows that letting go removes it.
    func moveLiftedTool(to point: CGPoint) {
        guard let reorder else { return }
        if let liftPoint { motion.follow(from: liftPoint, to: point) }
        let outside = reorder.removesRelease(at: point)
        if outside != motion.outside {
            motion.setOutside(outside)
            dragEffects.cursor(outside)
        }
        guard !outside else { return }
        guard let store = layoutStore, let slot = reorder.slot(at: point),
              let current = store.slots.firstIndex(of: reorder.tool), current != slot else { return }
        writeLayout { _ = store.placeTool(reorder.tool, at: slot, persist: false) }
    }

    /// Releasing keeps the order the island shows and saves it once. The
    /// tile then lands; the drawer stays until it has.
    func finishReorder(save: Bool = true) {
        layoutWatch = nil
        stopEscapeWatch()
        guard let reorder else { return }
        if motion.outside { motion.setOutside(false); dragEffects.cursor(false) }
        if save, let store = layoutStore, store.slots != reorder.original { store.saveLayout() }
        self.reorder = nil
        liftPoint = nil
        reorderPhase = ReorderPhase(state: .settling, tool: reorder.tool, generation: reorderPhase.generation)
        // If the island never reports the landing (it closed), let go anyway.
        scheduleSettleFallback(reorderGeneration)
    }

    /// Let go outside the hover: the tool leaves the island where it was
    /// dropped, with a poof, and its neighbours close the gap. The drawer
    /// stays (the edit hold) until a click outside or the pointer's return.
    // WHY: .project-docs/decisions/2026-11-27-hover-drag-out-and-smooth-edits.md
    func removeLiftedTool(at point: CGPoint, in window: NSWindow?) {
        guard let reorder else { return }
        layoutWatch = nil
        stopEscapeWatch()
        self.reorder = nil
        liftPoint = nil
        motion.setOutside(false)
        dragEffects.cursor(false)
        let generation = reorderGeneration
        var removed = false
        if let store = layoutStore {
            writeLayout { removed = store.unpin(reorder.tool) }
        }
        guard removed else {
            // Settings Sync took it out meanwhile: nothing left to remove.
            reorderPhase = ReorderPhase(state: .settling, tool: reorder.tool, generation: generation)
            scheduleSettleFallback(generation)
            return
        }
        // Let go outside the hover: the pointer is out, so its return and
        // next leave (or a click outside) close the drawer.
        pointerInside = false
        editHold.edited(pointerInside: false)
        reorderPhase = ReorderPhase(state: .removed, tool: reorder.tool, generation: generation)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if !Self.reducesMotion, let window {
            let screen = window.convertPoint(toScreen: point)
            dragEffects.poof(screen)
        }
        scheduleSettleFallback(generation)
    }

    private func scheduleSettleFallback(_ generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.didSettle(generation: generation)
        }
    }

    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// What a drag shows outside SwiftUI: the cursor and the system poof.
    /// Tests replace them; the poof is a window of its own.
    struct DragEffects {
        var cursor: (_ removing: Bool) -> Void
        var poof: (_ screenPoint: CGPoint) -> Void

        static let live = DragEffects(
            cursor: { removing in (removing ? NSCursor.disappearingItem : NSCursor.arrow).set() },
            poof: { point in NSAnimationEffect.poof.show(centeredAt: point, size: .zero) }
        )
        static let silent = DragEffects(cursor: { _ in }, poof: { _ in })
    }

    var dragEffects = DragEffects.live

    // Escape cancels a drag. The island is not key while the pointer drags,
    // so the key is watched for the drag's duration only and never consumed.
    private var escapeMonitors: [Any] = []

    private func startEscapeWatch() {
        stopEscapeWatch()
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handleDragKey(event) }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) {
            escapeMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            escapeMonitors.append(global)
        }
    }

    /// The Escape that cancelled the last drag. The edit-dismiss observer can
    /// see the same key before or after the drag's monitor does.
    private var lastDragEscape: TimeInterval?

    /// Escape while a tool is lifted belongs to the drag alone: it puts the
    /// tools back and never also closes a drawer held by an earlier edit.
    func handleDragKey(_ event: NSEvent) {
        guard event.type == .keyDown, event.keyCode == 53, isReordering else { return }
        lastDragEscape = event.timestamp
        cancelReorder()
    }

    /// True for an Escape the drag owns, whether the drag's monitor has
    /// already handled it or not; other observers must leave it alone.
    func escapeBelongsToDrag(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else { return false }
        return isReordering || event.timestamp == lastDragEscape
    }

    private func stopEscapeWatch() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors = []
    }

    /// The island finished landing the tile of `generation`.
    func didSettle(generation: Int) {
        // The picture of that lift goes too (a newer lift keeps its own).
        stage.clear(generation: generation)
        guard generation == reorderGeneration, reorder == nil,
              reorderPhase.state == .settling || reorderPhase.state == .removed else { return }
        reorderPhase = ReorderPhase(state: .idle, tool: nil, generation: generation)
    }

    /// Puts every tool back where it was before the lift (a release outside
    /// the tools, or Escape when the island already has keyboard focus).
    func cancelReorder() {
        guard let reorder else { return }
        // The saved layout was never touched during the drag: restore the
        // screen only, so a cancel writes nothing.
        if let store = layoutStore, let order = reorder.restoredOrder(current: store.slots), store.slots != order {
            writeLayout { store.replaceEditableSlots(with: order, persist: false) }
        }
        finishReorder(save: false)
        tracking.discardSequence()
    }

    private func writeLayout(_ change: () -> Void) {
        writingLayout = true
        defer { writingLayout = false }
        withAnimation(Self.reorderAnimation) { change() }
    }

    /// Neighbours make way with a soft, fully damped-out spring.
    static var reorderAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .spring(response: 0.32, dampingFraction: 0.86)
    }

    func setSurface(_ surface: IslandHoverHitTargetID.Surface) {
        activeSurface = surface
        cancelPress()
    }

    func setContext(_ context: String) {
        self.context = context
        cancelPress()
    }

    fileprivate func register(_ view: IslandHoverHitTargetView) {
        if let captured = tracking.captured, captured.owner == view.owner,
           (captured.id != view.targetID || captured.context != view.targetContext) {
            cancelPress()
        }
        targets[view.owner] = WeakTarget(view: view)
    }

    fileprivate func unregister(_ view: IslandHoverHitTargetView) {
        targets.removeValue(forKey: view.owner)
        if tracking.captured?.owner == view.owner { cancelPress() }
    }

    fileprivate func registerRegion(_ view: IslandHoverHitRegionView) {
        regions[view.surface] = WeakRegion(view: view)
    }

    fileprivate func unregisterRegion(_ view: IslandHoverHitRegionView) {
        if regions[view.surface]?.view === view {
            regions.removeValue(forKey: view.surface)
            if tracking.captured?.id.surface == view.surface { cancelPress() }
        }
    }

    fileprivate func registerModal(_ view: IslandHoverHitModalView) {
        modals[ObjectIdentifier(view)] = WeakModal(view: view)
        cancelPress()
    }

    fileprivate func unregisterModal(_ view: IslandHoverHitModalView) {
        modals[ObjectIdentifier(view)] = nil
    }

    /// Compute frames at event time, including scroll clipping. A search row
    /// must also intersect its measured viewport, never the search/footer.
    /// While a modal question is shown in this window, targets under it
    /// (Back, tiles) are left out and only the question's buttons remain.
    /// `includesInactive`: also targets whose primary action is disabled;
    /// only the context menu asks for them, clicks never reach them.
    private func snapshots(in window: NSWindow, allowsHover: Bool, allowsAnswer: Bool,
                           includesInactive: Bool = false) -> [IslandHoverHitSnapshot] {
        targets = targets.filter { $0.value.view != nil }
        modals = modals.filter { $0.value.view != nil }
        let modalShown = modals.values.contains { entry in
            guard let view = entry.view else { return false }
            return view.window === window && !view.isHiddenOrHasHiddenAncestor
        }
        return targets.values.compactMap { entry in
            guard let view = entry.view,
                  view.activates || includesInactive,
                  !modalShown || view.targetID.isModal,
                  accepts(view, allowsHover: allowsHover, allowsAnswer: allowsAnswer),
                  view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  let region = regions[view.targetID.surface]?.view, region.surface == view.targetID.surface,
                  region.window === window,
                  !region.isHiddenOrHasHiddenAncestor else { return nil }
            let targetFrame = view.convert(view.bounds, to: nil)
            let visibleFrame = view.convert(view.visibleRect, to: nil)
            let regionFrame = region.convert(region.visibleRect, to: nil)
            guard let clipped = IslandHoverHitGeometry.visibleFrame(
                target: targetFrame, visible: visibleFrame, region: regionFrame
            ) else { return nil }
            return IslandHoverHitSnapshot(owner: view.owner, id: view.targetID,
                                          context: view.targetContext, frame: clipped)
        }
        .sorted { $0.owner.uuidString < $1.owner.uuidString }
    }

    private func accepts(_ view: IslandHoverHitTargetView, allowsHover: Bool, allowsAnswer: Bool) -> Bool {
        let surface = view.targetID.surface
        if surface == .agentAnswer { return allowsAnswer }
        return allowsHover && view.targetContext == context
            && (surface == .update || surface == .deliveryFailure
                || (enabled && (surface == activeSurface || Self.isCompanion(surface, of: activeSurface))))
    }

    /// Surfaces on screen together with the tool grid.
    static func isCompanion(_ surface: IslandHoverHitTargetID.Surface,
                            of active: IslandHoverHitTargetID.Surface) -> Bool {
        active == .tile && (surface == .moreTools || surface == .moreToggle)
    }

    func mouseDown(at point: CGPoint, in window: NSWindow, allowed: Bool, allowsAnswer: Bool = false) -> Bool {
        finishReorder()
        let targets = snapshots(in: window, allowsHover: allowed, allowsAnswer: allowsAnswer)
        let consumed = tracking.begin(at: point, targets: targets, enabled: allowed || allowsAnswer)
        pressedID = tracking.captured?.id
        pressWindow = window
        pressPoint = point
        dragCandidate = tracking.captured.flatMap { captured in
            captured.id.surface == .tile
                && IslandHoverReorder.canLift(captured.id.tool, slots: layoutStore?.slots ?? []) ? captured : nil
        }
        return consumed
    }

    func mouseDragged(at point: CGPoint, in window: NSWindow, allowed: Bool, allowsAnswer: Bool = false) {
        if reorder == nil, startsDrag(at: point) { liftPressedTool(allowed: allowed) }
        if reorder != nil {
            if allowed { moveLiftedTool(to: point) }
            return
        }
        let targets = snapshots(in: window, allowsHover: allowed, allowsAnswer: allowsAnswer)
        tracking.move(at: point, targets: targets, enabled: allowed || allowsAnswer)
        pressedID = tracking.captured?.id
    }

    func mouseUp(at point: CGPoint, in window: NSWindow, allowed: Bool, allowsAnswer: Bool = false) {
        dragCandidate = nil
        if let reorder {
            // The landing starts from where the pointer let go.
            if let liftPoint { motion.follow(from: liftPoint, to: point) }
            if !allowed {
                // Hover dispatch stopped: keep the last allowed order, never
                // the cell under an ineligible release.
                finishReorder()
                tracking.discardSequence()
            } else if reorder.removesRelease(at: point) {
                removeLiftedTool(at: point, in: window)
                tracking.discardSequence()
            } else {
                moveLiftedTool(to: point)
                finishReorder()
                tracking.discardSequence()
            }
            pressedID = nil
            return
        }
        let liveTargets = snapshots(in: window, allowsHover: allowed, allowsAnswer: allowsAnswer)
        let owner = tracking.end(at: point, targets: liveTargets, enabled: allowed || allowsAnswer)
        let action = owner.flatMap { targets[$0]?.view?.activate }
        pressedID = nil
        action?()
    }
}

private struct IslandHoverNativePressedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct IslandAnswerHitBridgeKey: EnvironmentKey {
    static let defaultValue: IslandHoverHitBridge? = nil
}

extension EnvironmentValues {
    var islandAnswerHitBridge: IslandHoverHitBridge? {
        get { self[IslandAnswerHitBridgeKey.self] }
        set { self[IslandAnswerHitBridgeKey.self] = newValue }
    }

    var islandHoverNativePressed: Bool {
        get { self[IslandHoverNativePressedKey.self] }
        set { self[IslandHoverNativePressedKey.self] = newValue }
    }
}

private struct IslandHoverHitTargetModifier: ViewModifier {
    @ObservedObject var bridge: IslandHoverHitBridge
    @Environment(\.isEnabled) private var isEnabled
    let id: IslandHoverHitTargetID
    let context: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.islandHoverNativePressed, isEnabled && bridge.pressedID == id)
            // A disabled control still reports its frame, marked inactive, so
            // its context menu (Remove from Hover) works; clicks skip it.
            .background {
                IslandHoverHitTargetReporter(bridge: bridge, id: id, context: context,
                                             activates: isEnabled, action: action)
            }
    }
}

extension View {
    func islandHoverHitTarget(bridge: IslandHoverHitBridge, id: IslandHoverHitTargetID,
                             context: String, action: @escaping () -> Void) -> some View {
        modifier(IslandHoverHitTargetModifier(bridge: bridge, id: id, context: context, action: action))
    }

    func islandHoverHitRegion(bridge: IslandHoverHitBridge,
                              surface: IslandHoverHitTargetID.Surface) -> some View {
        background(IslandHoverHitRegionReporter(bridge: bridge, surface: surface))
    }

    /// Marks a question shown over the panel: while it is in the window, the
    /// window's first-mouse dispatch reaches only `.modal` targets.
    func islandHoverHitModal(bridge: IslandHoverHitBridge) -> some View {
        background(IslandHoverHitModalReporter(bridge: bridge))
    }
}

@MainActor
private struct IslandHoverHitModalReporter: NSViewRepresentable {
    let bridge: IslandHoverHitBridge

    func makeNSView(context: Context) -> IslandHoverHitModalView { IslandHoverHitModalView(frame: .zero) }
    func updateNSView(_ view: IslandHoverHitModalView, context: Context) {
        if view.bridge !== bridge { view.bridge?.unregisterModal(view) }
        view.bridge = bridge
        if view.window != nil { bridge.registerModal(view) }
    }
    static func dismantleNSView(_ view: IslandHoverHitModalView, coordinator: ()) {
        view.bridge?.unregisterModal(view)
        view.bridge = nil
    }
}

@MainActor
fileprivate final class IslandHoverHitModalView: NSView {
    weak var bridge: IslandHoverHitBridge?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { bridge?.registerModal(self) }
        else { bridge?.unregisterModal(self) }
    }
}

@MainActor
private struct IslandHoverHitTargetReporter: NSViewRepresentable {
    let bridge: IslandHoverHitBridge
    let id: IslandHoverHitTargetID
    let context: String
    let activates: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> IslandHoverHitTargetView {
        IslandHoverHitTargetView(frame: .zero)
    }

    func updateNSView(_ view: IslandHoverHitTargetView, context: Context) {
        view.bridge = bridge
        view.targetID = id
        view.targetContext = self.context
        view.activates = activates
        view.activate = action
        if view.window != nil { bridge.register(view) }
    }

    static func dismantleNSView(_ view: IslandHoverHitTargetView, coordinator: ()) {
        view.bridge?.unregister(view)
        view.bridge = nil
        view.activate = {}
    }
}

@MainActor
fileprivate final class IslandHoverHitTargetView: NSView {
    let owner = UUID()
    weak var bridge: IslandHoverHitBridge?
    var targetID = IslandHoverHitTargetID(surface: .tile, tool: .settings)
    var targetContext = ""
    /// False while the control is disabled: only its context menu sees it.
    var activates = true
    var activate: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { bridge?.register(self) }
        else { bridge?.unregister(self) }
    }
}

@MainActor
private struct IslandHoverHitRegionReporter: NSViewRepresentable {
    let bridge: IslandHoverHitBridge
    let surface: IslandHoverHitTargetID.Surface

    func makeNSView(context: Context) -> IslandHoverHitRegionView { IslandHoverHitRegionView(frame: .zero) }
    func updateNSView(_ view: IslandHoverHitRegionView, context: Context) {
        if view.bridge !== bridge || view.surface != surface { view.bridge?.unregisterRegion(view) }
        view.bridge = bridge
        view.surface = surface
        if view.window != nil { bridge.registerRegion(view) }
    }
    static func dismantleNSView(_ view: IslandHoverHitRegionView, coordinator: ()) {
        view.bridge?.unregisterRegion(view)
        view.bridge = nil
    }
}

@MainActor
fileprivate final class IslandHoverHitRegionView: NSView {
    weak var bridge: IslandHoverHitBridge?
    var surface: IslandHoverHitTargetID.Surface = .tile
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { bridge?.registerRegion(self) }
        else { bridge?.unregisterRegion(self) }
    }
}
