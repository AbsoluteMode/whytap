import AppKit
import SwiftUI

struct IslandHoverHitTargetID: Hashable {
    enum Surface: Hashable { case tile, result, meetingAssistant, update }
    enum UpdateAction: Hashable { case download, skip, install, later }
    private enum Control: Hashable { case tool(HoverTool), update(UpdateAction) }
    let surface: Surface
    private let control: Control
    var tool: HoverTool? { if case .tool(let tool) = control { return tool }; return nil }

    init(surface: Surface, tool: HoverTool) { self.surface = surface; control = .tool(tool) }
    init(update action: UpdateAction) { surface = .update; control = .update(action) }
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

/// The reporters are geometry sources, never mouse catchers. Dispatch remains
/// at NSWindow.sendEvent, the layer that receives first mouse in this overlay.
@MainActor
final class IslandHoverHitBridge: ObservableObject {
    @Published private(set) var pressedID: IslandHoverHitTargetID?
    private var tracking = IslandHoverPointerTracking()
    private var targets: [UUID: WeakTarget] = [:]
    private var regions: [IslandHoverHitTargetID.Surface: WeakRegion] = [:]
    private var enabled = false
    private var activeSurface: IslandHoverHitTargetID.Surface = .tile
    @Published private(set) var context = ""

    private struct WeakTarget { weak var view: IslandHoverHitTargetView? }
    private struct WeakRegion { weak var view: IslandHoverHitRegionView? }

    var consumesPointerSequence: Bool { tracking.consumesSequence }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { cancelPress() }
    }

    func cancelPress() {
        tracking.cancel()
        pressedID = nil
    }
    func cancelPress(for surface: IslandHoverHitTargetID.Surface) {
        if tracking.captured?.id.surface == surface { cancelPress() }
    }

    func discardSequence() {
        tracking.discardSequence()
        pressedID = nil
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

    /// Compute frames at event time, including scroll clipping. A search row
    /// must also intersect its measured viewport, never the search/footer.
    private func snapshots(in window: NSWindow) -> [IslandHoverHitSnapshot] {
        targets = targets.filter { $0.value.view != nil }
        return targets.values.compactMap { entry in
            guard let view = entry.view,
                  enabled || view.targetID.surface == .update,
                  view.targetID.surface == activeSurface || view.targetID.surface == .meetingAssistant || view.targetID.surface == .update,
                  view.targetContext == context,
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

    func mouseDown(at point: CGPoint, in window: NSWindow, allowed: Bool) -> Bool {
        let consumed = tracking.begin(at: point, targets: snapshots(in: window), enabled: allowed)
        pressedID = tracking.captured?.id
        return consumed
    }

    func mouseDragged(at point: CGPoint, in window: NSWindow, allowed: Bool) {
        tracking.move(at: point, targets: snapshots(in: window), enabled: allowed)
        pressedID = tracking.captured?.id
    }

    func mouseUp(at point: CGPoint, in window: NSWindow, allowed: Bool) {
        let owner = tracking.end(at: point, targets: snapshots(in: window), enabled: allowed)
        let action = owner.flatMap { targets[$0]?.view?.activate }
        pressedID = nil
        action?()
    }
}

private struct IslandHoverNativePressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var islandHoverNativePressed: Bool {
        get { self[IslandHoverNativePressedKey.self] }
        set { self[IslandHoverNativePressedKey.self] = newValue }
    }
}

private struct IslandHoverHitTargetModifier: ViewModifier {
    @ObservedObject var bridge: IslandHoverHitBridge
    let id: IslandHoverHitTargetID
    let context: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.islandHoverNativePressed, bridge.pressedID == id)
            .background(IslandHoverHitTargetReporter(bridge: bridge, id: id, context: context, action: action))
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
