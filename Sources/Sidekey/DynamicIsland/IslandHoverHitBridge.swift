import AppKit
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

/// A tool lifted by a long press in the island's tool grid. The grid's cells
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

    /// The slot under the pointer, or nil outside the grid (the tool stays).
    func slot(at point: CGPoint) -> Int? {
        cells.filter { $0.value.contains(point) }.keys.min()
    }

    /// Settings is always last and cannot be lifted; a tool that is not in
    /// the island has no cell to leave.
    static func canLift(_ tool: HoverTool?, slots: [HoverTool]) -> Bool {
        guard let tool, tool != .settings, !tool.isComingSoon else { return false }
        return slots.contains(tool)
    }
}

/// The reporters are geometry sources, never mouse catchers. Dispatch remains
/// at NSWindow.sendEvent, the layer that receives first mouse in this overlay.
@MainActor
final class IslandHoverHitBridge: ObservableObject {
    @Published private(set) var pressedID: IslandHoverHitTargetID?
    /// The tool held up by a long press, while it is being moved.
    @Published private(set) var reorderingTool: HoverTool?
    var isReordering: Bool { reorderingTool != nil }
    /// The layout the island shows. A long press on a tile moves tools here,
    /// the same store Settings -> Features -> Hover shows.
    weak var layoutStore: HoverLayoutStore?
    /// How long a tile is held before it lifts (a shorter press is a click).
    var reorderHoldDelay: Duration = .milliseconds(350)
    private var reorder: IslandHoverReorder?
    private var holdTask: Task<Void, Never>?
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
        holdTask?.cancel()
        holdTask = nil
        tracking.cancel()
        pressedID = nil
    }
    func cancelPress(for surface: IslandHoverHitTargetID.Surface) {
        if tracking.captured?.id.surface == surface { cancelPress() }
    }

    func discardSequence() {
        holdTask?.cancel()
        holdTask = nil
        tracking.discardSequence()
        pressedID = nil
        finishReorder()
    }

    // MARK: - Long-press reorder

    /// Lifts the tile still held since mouse-down. Called by the hold timer;
    /// returns false when the press was released, left its tile or is not a
    /// tool that can move. From here on the press never activates the tool.
    @discardableResult
    func liftPressedTool() -> Bool {
        holdTask?.cancel()
        holdTask = nil
        guard reorder == nil, let captured = tracking.captured, captured.id.surface == .tile,
              let store = layoutStore, IslandHoverReorder.canLift(captured.id.tool, slots: store.slots),
              let tool = captured.id.tool, let window = pressWindow else { return false }
        var cells: [Int: CGRect] = [:]
        for tile in snapshots(in: window, allowsHover: true, allowsAnswer: false)
        where tile.id.surface == .tile && tile.context == captured.context {
            if let placed = tile.id.tool, let index = store.slots.firstIndex(of: placed) { cells[index] = tile.frame }
        }
        reorder = IslandHoverReorder(tool: tool, original: store.slots, cells: cells)
        tracking.cancel()
        pressedID = nil
        reorderingTool = tool
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        return true
    }

    /// The lifted tool takes the place of the cell under the pointer at once.
    func moveLiftedTool(to point: CGPoint) {
        guard let reorder, let store = layoutStore, let slot = reorder.slot(at: point),
              store.slots.firstIndex(of: reorder.tool) != slot else { return }
        withAnimation(Self.reorderAnimation) { _ = store.placeTool(reorder.tool, at: slot) }
    }

    /// Releasing keeps the order the island shows (it is already saved).
    func finishReorder() {
        guard reorder != nil else { return }
        reorder = nil
        reorderingTool = nil
    }

    /// Escape puts every tool back where it was before the lift.
    func cancelReorder() {
        guard let reorder else { return }
        if let store = layoutStore, store.slots != reorder.original {
            withAnimation(Self.reorderAnimation) { store.replaceEditableSlots(with: reorder.original) }
        }
        finishReorder()
        tracking.discardSequence()
    }

    private static var reorderAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .spring(response: 0.26, dampingFraction: 0.84)
    }

    private func scheduleLift() {
        holdTask?.cancel()
        holdTask = nil
        guard tracking.captured?.id.surface == .tile,
              IslandHoverReorder.canLift(tracking.captured?.id.tool, slots: layoutStore?.slots ?? []) else { return }
        let owner = tracking.captured?.owner
        let delay = reorderHoldDelay
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.tracking.captured?.owner == owner else { return }
            self.liftPressedTool()
        }
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
        scheduleLift()
        return consumed
    }

    func mouseDragged(at point: CGPoint, in window: NSWindow, allowed: Bool, allowsAnswer: Bool = false) {
        if reorder != nil {
            moveLiftedTool(to: point)
            return
        }
        let targets = snapshots(in: window, allowsHover: allowed, allowsAnswer: allowsAnswer)
        tracking.move(at: point, targets: targets, enabled: allowed || allowsAnswer)
        pressedID = tracking.captured?.id
        if tracking.captured == nil { holdTask?.cancel(); holdTask = nil }
    }

    func mouseUp(at point: CGPoint, in window: NSWindow, allowed: Bool, allowsAnswer: Bool = false) {
        holdTask?.cancel()
        holdTask = nil
        if reorder != nil {
            moveLiftedTool(to: point)
            finishReorder()
            tracking.discardSequence()
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
