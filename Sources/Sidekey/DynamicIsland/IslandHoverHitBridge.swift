import AppKit
import Combine
import SwiftUI

struct IslandHoverHitTargetID: Hashable {
    enum Surface: Hashable { case tile, result, navigation, update, deliveryFailure, agentAnswer }
    enum UpdateAction: Hashable { case download, skip, install, later }
    enum DisplayAction: Hashable { case hold }
    enum DeliveryFailureAction: Hashable { case retry, dismiss }
    /// Buttons of a question shown over a panel (Monitor's delete question).
    enum ModalAction: Hashable { case cancel, confirm }
    private enum Control: Hashable {
        case tool(HoverTool), back(String), update(UpdateAction), display(DisplayAction)
        case deliveryFailure(DeliveryFailureAction), tableDisclosure(UUID), modal(ModalAction)
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

    /// How far past the grid a release still counts as "in the grid".
    static let releaseMargin: CGFloat = 24

    /// The slot under the pointer, or nil outside the grid (the tool stays).
    func slot(at point: CGPoint) -> Int? {
        cells.filter { $0.value.contains(point) }.keys.min()
    }

    /// Letting go well outside the tools puts them back as they were: the
    /// pointer's way to cancel, since the island is not key during a drag.
    func cancelsRelease(at point: CGPoint) -> Bool {
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

    func reset() { if translation != .zero { translation = .zero } }
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
        enum State: Equatable { case idle, lifted, settling }
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
    var settlingTool: HoverTool? { reorderPhase.state == .settling ? reorderPhase.tool : nil }
    /// Counts lifts, so an older landing never ends a newer one.
    var reorderGeneration: Int { reorderPhase.generation }
    /// The drawer stays open through the drag and its landing.
    var holdsDrawer: Bool { reorderingTool != nil || settlingTool != nil }
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
        reorder = IslandHoverReorder(tool: tool, original: store.slots, cells: cells)
        liftPoint = pressPoint
        motion.reset()
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

    /// The lifted tool takes the place of the cell under the pointer at once.
    func moveLiftedTool(to point: CGPoint) {
        guard let reorder else { return }
        if let liftPoint { motion.follow(from: liftPoint, to: point) }
        guard let store = layoutStore, let slot = reorder.slot(at: point),
              let current = store.slots.firstIndex(of: reorder.tool), current != slot else { return }
        writeLayout { _ = store.placeTool(reorder.tool, at: slot, persist: false) }
    }

    /// Releasing keeps the order the island shows and saves it once. The
    /// tile then lands; the drawer stays until it has.
    func finishReorder(save: Bool = true) {
        layoutWatch = nil
        guard let reorder else { return }
        if save, let store = layoutStore, store.slots != reorder.original { store.saveLayout() }
        self.reorder = nil
        liftPoint = nil
        reorderPhase = ReorderPhase(state: .settling, tool: reorder.tool, generation: reorderPhase.generation)
        let generation = reorderGeneration
        // If the island never reports the landing (it closed), let go anyway.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.didSettle(generation: generation)
        }
    }

    /// The island finished landing the tile of `generation`.
    func didSettle(generation: Int) {
        // The picture of that lift goes too (a newer lift keeps its own).
        stage.clear(generation: generation)
        guard generation == reorderGeneration, reorder == nil, reorderPhase.state == .settling else { return }
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
    private func snapshots(in window: NSWindow, allowsHover: Bool, allowsAnswer: Bool) -> [IslandHoverHitSnapshot] {
        targets = targets.filter { $0.value.view != nil }
        modals = modals.filter { $0.value.view != nil }
        let modalShown = modals.values.contains { entry in
            guard let view = entry.view else { return false }
            return view.window === window && !view.isHiddenOrHasHiddenAncestor
        }
        return targets.values.compactMap { entry in
            guard let view = entry.view,
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
            && (surface == .update || surface == .deliveryFailure || (enabled && surface == activeSurface))
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
            } else if reorder.cancelsRelease(at: point) {
                cancelReorder()
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
            .background {
                if isEnabled {
                    IslandHoverHitTargetReporter(bridge: bridge, id: id, context: context, action: action)
                }
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
    let action: () -> Void

    func makeNSView(context: Context) -> IslandHoverHitTargetView {
        IslandHoverHitTargetView(frame: .zero)
    }

    func updateNSView(_ view: IslandHoverHitTargetView, context: Context) {
        view.bridge = bridge
        view.targetID = id
        view.targetContext = self.context
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
