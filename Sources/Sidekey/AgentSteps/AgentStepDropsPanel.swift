import AppKit
import Combine
import SwiftUI

/// The panel the Agent's step drops live in: in the menu bar right of the
/// island, just under its window level. It follows the system appearance
/// (the island window is always dark), is never key or main, and never takes
/// the mouse: the drops only show, so the menu bar extras under them keep
/// working. On screen only from just before the first drop to just after
/// the last.
/// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
@MainActor
final class AgentStepDropsPanel: NSPanel {
    private var host: NSHostingView<AgentStepDropsView>!

    init(model: AgentStepDropsModel) {
        let frame = Self.frame(on: IslandScreenResolver.currentDescriptor())
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isMovable = false
        hidesOnDeactivate = false; isFloatingPanel = true; ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        sharingType = PrivacyPreferences.shared.screenshotProtectionEnabled ? .none : .readOnly
        // Just below the island (`.screenSaver`), above the menu bar.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        let host = NSHostingView(rootView: AgentStepDropsView(model: model))
        self.host = host
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
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }

    func setScreenshotProtectionEnabled(_ enabled: Bool) {
        sharingType = enabled ? .none : .readOnly
    }

    @objc private func reposition() {
        let frame = Self.frame(on: IslandScreenResolver.currentDescriptor())
        setFrame(frame, display: true)
        host.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Starts under the island's right edge and runs right along the menu
    /// bar, as tall as the island's compact pill, never past the screen.
    static func frame(island: NSRect, screenMaxX: CGFloat) -> NSRect {
        let x = island.maxX - AgentStepDropsView.Metrics.islandOverlap
        let width = min(AgentStepDropsView.Metrics.panelWidth, max(0, screenMaxX - x))
        return NSRect(x: x, y: island.minY, width: width, height: island.height)
    }

    static func frame(on screen: IslandScreenDescriptor) -> NSRect {
        frame(island: IslandFrameLayout.islandFrame(on: screen), screenMaxX: screen.frame.maxX)
    }
}

/// Decides when a finished turn's steps may show: only while the island is
/// idle. Steps that arrive during a dictation wait for it to end; an island
/// that gets busy while drops are shown puts them out.
/// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
@MainActor
final class AgentStepDropsController {
    /// Steps older than this when the island gets free are not shown; they
    /// are in History.
    static let waitLimit: TimeInterval = 20

    let model: AgentStepDropsModel
    private let now: () -> Date
    private let announce: (String) -> Void
    private var islandIsIdle = true
    private var waiting: (steps: [AgentAppStep], since: Date)?
    private var idleObserver: AnyCancellable?

    init(model: AgentStepDropsModel,
         present: @escaping (Bool) -> Void,
         islandIdle: AnyPublisher<Bool, Never>,
         now: @escaping () -> Date = Date.init,
         announce: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.now = now
        self.announce = announce
        model.onVisibleChange = present
        idleObserver = islandIdle.removeDuplicates().sink { [weak self] idle in
            guard let self else { return }
            self.islandIsIdle = idle
            if !idle {
                self.model.dismissForBusyIsland()
            } else if let waiting = self.waiting {
                self.waiting = nil
                if self.now().timeIntervalSince(waiting.since) <= Self.waitLimit { self.display(waiting.steps) }
            }
        }
    }

    /// A turn finished with only its Whytap changes to show.
    func show(_ steps: [AgentAppStep]) {
        guard !steps.isEmpty else { return }
        guard islandIsIdle else {
            waiting = (steps, now())
            return
        }
        display(steps)
    }

    /// Sleep or quit: nothing stays on screen or waits.
    func dismiss() {
        waiting = nil
        model.dismissForBusyIsland()
    }

    private func display(_ steps: [AgentAppStep]) {
        model.show(steps)
        // The panel never takes focus; VoiceOver hears the steps instead.
        announce(steps.map(\.line).joined(separator: ". "))
    }

    /// The app's controller and panel. `agentFlow` is the store the island
    /// renders from (the one handed to `IslandPanel.installAgentFlow`).
    static func live(agentFlow: IslandAgentFlowStore) -> (AgentStepDropsController, AgentStepDropsPanel) {
        let model = AgentStepDropsModel(reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
        let panel = AgentStepDropsPanel(model: model)
        let idle = AppState.shared.$phase
            .combineLatest(AppState.shared.$agentPhase, agentFlow.$answerPanelVisible)
            .map { drop, agent, answerVisible in drop == .idle && agent == .idle && !answerVisible }
            .eraseToAnyPublisher()
        let controller = AgentStepDropsController(
            model: model,
            present: { [weak panel] visible in visible ? panel?.present() : panel?.dismiss() },
            islandIdle: idle,
            announce: { text in
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        )
        return (controller, panel)
    }
}
