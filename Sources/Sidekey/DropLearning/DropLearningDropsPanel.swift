import AppKit
import Carbon.HIToolbox
import Combine
import os.log
import SwiftUI

private final class DropsHostingView<Content: View>: NSHostingView<Content> {
    var accepts: (CGPoint) -> Bool = { _ in false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let topLeft = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        guard accepts(topLeft) else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the row and Y/N are, in the drops view's top-left space, and the
/// press in flight. The panel answers the pointer itself: in an inactive
/// app's non-activating panel AppKit never hands the first click to SwiftUI,
/// not even with `acceptsFirstMouse` (the island's ✕ had the same bug,
/// docs/bugs/2026-09-04-island-answer-close-first-mouse.md), so a SwiftUI
/// Button there never fires.
/// WHY: .project-docs/decisions/2026-11-22-drop-learning-drops.md
struct DropLearningDropsPointer: Equatable {
    enum Area: Hashable { case row, yes, no }
    /// Room around the row and the buttons that still counts as on them.
    static let slop: CGFloat = 3

    private(set) var frames: [Area: CGRect] = [:]
    private(set) var pressed: DropLearningDropsModel.Button?
    /// A press began on the row: its drags and release are ours too, so
    /// nothing reaches the menu bar under it.
    private(set) var ownsSequence = false

    mutating func set(_ area: Area, frame: CGRect) { frames[area] = frame }

    func isOnRow(_ point: CGPoint) -> Bool {
        frames[.row].map { $0.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) } ?? false
    }

    func button(at point: CGPoint) -> DropLearningDropsModel.Button? {
        let on = { (area: Area) in frames[area]?.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) == true }
        if on(.yes) { return .yes }
        if on(.no) { return .no }
        return nil
    }

    /// Returns whether the press is ours.
    mutating func down(at point: CGPoint) -> Bool {
        pressed = button(at: point)
        ownsSequence = pressed != nil || isOnRow(point)
        return ownsSequence
    }

    /// The button the press began and ended on, if any: that is the answer.
    mutating func up(at point: CGPoint) -> DropLearningDropsModel.Button? {
        defer { cancel() }
        guard let pressed, button(at: point) == pressed else { return nil }
        return pressed
    }

    mutating func cancel() {
        pressed = nil
        ownsSequence = false
    }
}

/// The non-activating panel the suggestion drops live in, in the menu bar
/// right of the island and just under its edge, so the first drop buds from
/// the island. It follows the system appearance (the island window is always
/// dark). Never key, never main; shown only while drops are on screen. It
/// takes the mouse only while the pointer is over the row, so the menu bar
/// extras under the rest of it keep working.
/// WHY: .project-docs/decisions/2026-11-22-drop-learning-drops.md
@MainActor
final class DropLearningDropsPanel: NSPanel {
    static let width: CGFloat = 520

    /// A click on Y or N.
    var onAnswer: ((DropLearningDropsModel.Button) -> Void)?
    /// The pointer is on the row, and on which button.
    var onPointer: ((Bool, DropLearningDropsModel.Button?) -> Void)?
    /// The button the mouse is down on, nil once it is up.
    var onPress: ((DropLearningDropsModel.Button?) -> Void)?

    private var host: DropsHostingView<DropLearningDropsView>!
    private(set) var pointer = DropLearningDropsPointer()
    private var mouseMonitors: [Any] = []

    init(model: DropLearningDropsModel) {
        let frame = Self.frame(on: IslandScreenResolver.currentDescriptor())
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isMovable = false
        hidesOnDeactivate = false; isFloatingPanel = true; ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        sharingType = PrivacyPreferences.shared.screenshotProtectionEnabled ? .none : .readOnly
        // Just below the island (`.screenSaver`), above the menu bar: the
        // island covers the drop that buds from under its edge.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        let host = DropsHostingView(rootView: DropLearningDropsView(model: model))
        self.host = host
        host.rootView = DropLearningDropsView(model: model, onFrame: { [weak self] area, rect in
            self?.pointer.set(area, frame: rect)
        })
        host.accepts = { [weak self] point in self?.pointer.isOnRow(point) ?? false }
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
        for name in [NSApplication.didChangeScreenParametersNotification, IslandScreenResolver.selectionDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func present() {
        reposition()
        pointer.cancel()
        startPointerRouting()
        orderFrontRegardless()
        refreshPointer()
    }

    func dismiss() {
        stopPointerRouting()
        pointer.cancel()
        onPress?(nil)
        ignoresMouseEvents = true
        orderOut(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if pointer.down(at: viewPoint(window: event.locationInWindow)) {
                onPress?(pointer.pressed)
                return
            }
        case .leftMouseDragged where pointer.ownsSequence:
            return
        case .leftMouseUp where pointer.ownsSequence:
            let answer = pointer.up(at: viewPoint(window: event.locationInWindow))
            onPress?(nil)
            if let answer { onAnswer?(answer) }
            refreshPointer()
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    // MARK: - Pointer

    private func startPointerRouting() {
        guard mouseMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPointer() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.refreshPointer()
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func stopPointerRouting() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }

    /// Claims the mouse only over the row, and tells the model where the
    /// pointer is (hover pauses the 10 s; Y/N show ✓/✕).
    private func refreshPointer() {
        guard isVisible else { return }
        let point = viewPoint(window: convertPoint(fromScreen: NSEvent.mouseLocation))
        let onRow = pointer.isOnRow(point)
        if !pointer.ownsSequence, ignoresMouseEvents == onRow { ignoresMouseEvents = !onRow }
        onPointer?(onRow, onRow ? pointer.button(at: point) : nil)
    }

    private func viewPoint(window point: NSPoint) -> CGPoint {
        let local = host.convert(point, from: nil)
        return CGPoint(x: local.x, y: host.isFlipped ? local.y : host.bounds.height - local.y)
    }

    func setScreenshotProtectionEnabled(_ enabled: Bool) {
        sharingType = enabled ? .none : .readOnly
    }

    @objc private func reposition() {
        let frame = Self.frame(on: IslandScreenResolver.currentDescriptor())
        setFrame(frame, display: true)
        host.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Starts under the island's right edge and runs right along the menu
    /// bar, as tall as the island's compact pill.
    static func frame(island: NSRect) -> NSRect {
        NSRect(
            x: island.maxX - DropLearningDropsView.Metrics.islandOverlap,
            y: island.minY,
            width: width,
            height: island.height
        )
    }

    static func frame(on screen: IslandScreenDescriptor) -> NSRect {
        frame(island: IslandFrameLayout.islandFrame(on: screen))
    }
}

/// ⌃Y and ⌃N while the drops are on screen, and ⌃ alone to light Y and N.
/// Carbon hot keys take only those two combinations and only between show
/// and hide; plain Y and N always reach the field.
/// WHY: .project-docs/decisions/2026-11-22-drop-learning-drops.md
@MainActor
protocol DropLearningKeyCapturing: AnyObject {
    func start(onAnswer: @escaping @MainActor (DropLearningDropsModel.Button) -> Void,
               onControl: @escaping @MainActor (Bool) -> Void)
    func stop()
}

/// The two answer combinations, reserved in the Hotkeys conflict check.
enum DropLearningKeyCombos {
    static let yes = HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey), keyTitle: "Y")
    static let no = HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey), keyTitle: "N")
}

@MainActor
final class DropLearningKeys: DropLearningKeyCapturing {

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "drop-learning")
    private var monitors: [CarbonHotkeyMonitor] = []
    private var flagMonitors: [Any] = []

    func start(onAnswer: @escaping @MainActor (DropLearningDropsModel.Button) -> Void,
               onControl: @escaping @MainActor (Bool) -> Void) {
        stop()
        for (combo, id, button) in [(DropLearningKeyCombos.yes, CarbonHotkeyMonitor.dropLearningYesHotKeyID, DropLearningDropsModel.Button.yes),
                                    (DropLearningKeyCombos.no, CarbonHotkeyMonitor.dropLearningNoHotKeyID, .no)] {
            let monitor = CarbonHotkeyMonitor(
                keyCode: combo.keyCode, modifiers: combo.modifiers, hotKeyIDValue: id,
                onHotkey: {
                    // No key data: only that ⌃Y or ⌃N reached Whytap.
                    os_log("drop_learning_answer_key yes=%{public}d", log: Self.log, type: .info, button == .yes ? 1 : 0)
                    MainActor.assumeIsolated { onAnswer(button) }
                }
            )
            // A combination another app holds just stays with it; the
            // drops still answer to a click.
            if (try? monitor.start()) != nil { monitors.append(monitor) }
        }
        let handle: (NSEvent) -> Void = { event in
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
            MainActor.assumeIsolated { onControl(held) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle) {
            flagMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handle($0); return $0 }) {
            flagMonitors.append(local)
        }
        onControl(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control)
    }

    func stop() {
        monitors.forEach { $0.stop() }
        monitors.removeAll()
        flagMonitors.forEach(NSEvent.removeMonitor)
        flagMonitors.removeAll()
    }
}

/// Wires the coordinator, the model, the panel and the keys. Suggestions
/// show only while the island is idle; leaving idle puts them out.
@MainActor
final class DropLearningDropsController {
    let model: DropLearningDropsModel
    private let keys: DropLearningKeyCapturing
    private let present: (Bool) -> Void
    private var islandIsIdle = false
    private var phaseObserver: AnyCancellable?

    init(
        coordinator: DropLearningCoordinator,
        model: DropLearningDropsModel,
        keys: DropLearningKeyCapturing,
        present: @escaping (Bool) -> Void,
        phase: AnyPublisher<AppPhase, Never>,
        agentPhase: AnyPublisher<AgentPhase, Never>,
        agentAnswerVisible: AnyPublisher<Bool, Never>
    ) {
        self.model = model
        self.keys = keys
        self.present = present
        coordinator.onSuggestion = { [weak self] suggestion in
            guard let self, self.islandIsIdle else { return false }
            return self.model.show(suggestion)
        }
        model.onOutcome = { [weak coordinator] suggestion, outcome, via in
            switch outcome {
            case .accepted: coordinator?.accept(suggestion, via: via.rawValue)
            case .declined: coordinator?.decline(suggestion, via: via.rawValue)
            case .expired: coordinator?.expired(suggestion, via: via.rawValue)
            }
        }
        model.onVisibleChange = { [weak self] visible in self?.visibilityChanged(visible) }
        phaseObserver = phase.combineLatest(agentPhase, agentAnswerVisible)
            .map { drop, agent, answerVisible in drop == .idle && agent == .idle && !answerVisible }
            .removeDuplicates()
            .sink { [weak self] isIdle in
                guard let self else { return }
                self.islandIsIdle = isIdle
                if !isIdle { self.model.dismissForBusyIsland() }
            }
    }

    private func visibilityChanged(_ visible: Bool) {
        present(visible)
        if visible {
            keys.start(
                onAnswer: { [weak model] in model?.answer($0) },
                onControl: { [weak model] in model?.setControlHeld($0) }
            )
        } else {
            keys.stop()
        }
    }

    /// Clicks and the pointer on the panel reach the model.
    static func wire(_ panel: DropLearningDropsPanel, to model: DropLearningDropsModel) {
        panel.onAnswer = { [weak model] in model?.answer($0, via: .click) }
        panel.onPress = { [weak model] in model?.setPressedButton($0) }
        panel.onPointer = { [weak model] onRow, button in
            model?.setHovered(onRow)
            model?.setHoveredButton(button)
        }
    }

    /// The app's controller.
    static func live(coordinator: DropLearningCoordinator) -> (DropLearningDropsController, DropLearningDropsPanel) {
        let model = DropLearningDropsModel(reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
        let panel = DropLearningDropsPanel(model: model)
        wire(panel, to: model)
        let controller = DropLearningDropsController(
            coordinator: coordinator, model: model, keys: DropLearningKeys(),
            present: { [weak panel] visible in visible ? panel?.present() : panel?.dismiss() },
            phase: AppState.shared.$phase.eraseToAnyPublisher(),
            agentPhase: AppState.shared.$agentPhase.eraseToAnyPublisher(),
            agentAnswerVisible: IslandPanel.shared.agentFlow.$answerPanelVisible.eraseToAnyPublisher()
        )
        return (controller, panel)
    }
}
