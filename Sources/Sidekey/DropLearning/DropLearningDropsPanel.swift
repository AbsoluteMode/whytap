import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

private final class DropsHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: NSRect = .zero
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
    /// A click answers without activating Whytap: the field keeps focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The non-activating panel the suggestion drops live in, in the menu bar
/// right of the island and just under its edge, so the first drop buds from
/// the island. It follows the system appearance (the island window is always
/// dark). Never key, never main; shown only while drops are on screen.
/// WHY: .project-docs/decisions/2026-11-22-drop-learning-drops.md
@MainActor
final class DropLearningDropsPanel: NSPanel {
    static let width: CGFloat = 520

    private var host: DropsHostingView<DropLearningDropsView>!

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
        host.rootView = DropLearningDropsView(model: model, onRowFrame: { [weak self] rect in
            guard let self else { return }
            let height = self.host.bounds.height
            self.host.interactiveRect = NSRect(
                x: rect.minX - 4,
                y: self.host.isFlipped ? rect.minY - 4 : height - rect.maxY - 4,
                width: rect.width + 8, height: rect.height + 8
            )
        })
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
        ignoresMouseEvents = false
        orderFrontRegardless()
    }

    func dismiss() {
        ignoresMouseEvents = true
        orderOut(nil)
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

    private var monitors: [CarbonHotkeyMonitor] = []
    private var flagMonitors: [Any] = []

    func start(onAnswer: @escaping @MainActor (DropLearningDropsModel.Button) -> Void,
               onControl: @escaping @MainActor (Bool) -> Void) {
        stop()
        for (combo, id, button) in [(DropLearningKeyCombos.yes, CarbonHotkeyMonitor.dropLearningYesHotKeyID, DropLearningDropsModel.Button.yes),
                                    (DropLearningKeyCombos.no, CarbonHotkeyMonitor.dropLearningNoHotKeyID, .no)] {
            let monitor = CarbonHotkeyMonitor(
                keyCode: combo.keyCode, modifiers: combo.modifiers, hotKeyIDValue: id,
                onHotkey: { MainActor.assumeIsolated { onAnswer(button) } }
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
    private var phaseObserver: AnyCancellable?

    init(
        coordinator: DropLearningCoordinator,
        model: DropLearningDropsModel,
        keys: DropLearningKeyCapturing,
        present: @escaping (Bool) -> Void,
        phase: AnyPublisher<AppPhase, Never>
    ) {
        self.model = model
        self.keys = keys
        self.present = present
        coordinator.onSuggestion = { [weak model] suggestion in model?.show(suggestion) }
        model.onOutcome = { [weak coordinator] suggestion, outcome in
            switch outcome {
            case .accepted: coordinator?.accept(suggestion)
            case .declined: coordinator?.decline(suggestion)
            case .expired: coordinator?.expired(suggestion)
            }
        }
        model.onVisibleChange = { [weak self] visible in self?.visibilityChanged(visible) }
        phaseObserver = phase.sink { [weak model] phase in
            if phase != .idle { model?.dismissForBusyIsland() }
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

    /// The app's controller.
    static func live(coordinator: DropLearningCoordinator) -> (DropLearningDropsController, DropLearningDropsPanel) {
        let model = DropLearningDropsModel(reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
        let panel = DropLearningDropsPanel(model: model)
        let controller = DropLearningDropsController(
            coordinator: coordinator, model: model, keys: DropLearningKeys(),
            present: { [weak panel] visible in visible ? panel?.present() : panel?.dismiss() },
            phase: AppState.shared.$phase.removeDuplicates().eraseToAnyPublisher()
        )
        return (controller, panel)
    }
}
