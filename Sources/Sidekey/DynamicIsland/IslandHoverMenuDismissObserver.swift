import AppKit
import SwiftUI

/// Explicitly opened menus survive pointer exit. Observe dismissal without
/// swallowing the outside click or Escape sent to another application.
struct IslandHoverMenuDismissObserver: NSViewRepresentable {
    var enabled: Bool
    /// False: Escape typed into another Whytap window (Settings) is passed
    /// on to it after dismissing; only Escape aimed at the island is consumed.
    var consumesEscapeElsewhere = true
    var onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onDismiss = onDismiss
        context.coordinator.consumesEscapeElsewhere = consumesEscapeElsewhere
        context.coordinator.setEnabled(enabled)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setEnabled(false)
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onDismiss: () -> Void = {}
        var consumesEscapeElsewhere = true
        private var local: Any?
        private var global: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var trackingMenus = 0

        func setEnabled(_ enabled: Bool) {
            guard enabled else {
                if let local { NSEvent.removeMonitor(local) }
                if let global { NSEvent.removeMonitor(global) }
                local = nil
                global = nil
                menuObservers.forEach(NotificationCenter.default.removeObserver)
                menuObservers = []
                trackingMenus = 0
                return
            }
            guard local == nil else { return }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self, self.shouldDismiss(event) else { return event }
                self.onDismiss()
                return self.consumes(event) ? nil : event
            }
            global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.shouldDismiss(event) else { return }
                    self.onDismiss()
                }
            }
            let center = NotificationCenter.default
            menuObservers = [
                center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trackingMenus += 1 }
                },
                center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.trackingMenus = max(0, self.trackingMenus - 1)
                    }
                }
            ]
        }

        /// Escape aimed at the island ends there; a click always passes on.
        func consumes(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            return consumesEscapeElsewhere || event.window == nil || event.window === view?.window
        }

        func shouldDismiss(_ event: NSEvent, at screenPoint: NSPoint? = nil) -> Bool {
            guard trackingMenus == 0, NSApp.modalWindow == nil,
                  !NSApp.windows.contains(where: { $0.isVisible && ($0 is NSSavePanel || $0.attachedSheet != nil) }),
                  let view, let window = view.window else { return false }
            if event.type == .keyDown {
                return event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            }
            let point = view.convert(window.convertPoint(fromScreen: screenPoint ?? NSEvent.mouseLocation), from: nil)
            return !view.bounds.contains(point)
        }
    }
}
