import AppKit
import SwiftUI

/// Hosts the onboarding in one fixed-size window beside the island. The app
/// stays an accessory (no Dock icon), as Settings does. Closing the window
/// finishes the onboarding just like Done.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    private let onClosed: () -> Void
    private var didClose = false

    init(model: OnboardingModel, onClosed: @escaping () -> Void) {
        self.model = model
        self.onClosed = onClosed
        let size = OnboardingView.size
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Whytap"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        window.setContentSize(size)
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController only supports programmatic init.")
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        guard let window else { return }
        SidekeyWindowChrome.centerOnMainScreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        model.stop()
        onClosed()
    }
}
