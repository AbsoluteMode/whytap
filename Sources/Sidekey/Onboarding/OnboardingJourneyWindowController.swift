import AppKit
import SwiftUI

/// Hosts the onboarding in one small fixed-size window beside the island. The app
/// stays an accessory (no Dock icon), as Settings does. Closing the window
/// finishes the onboarding just like Done.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingJourneyWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingJourneyModel
    private let onClosed: () -> Void
    private var didClose = false
    private var keyMonitor: Any?

    init(model: OnboardingJourneyModel, onClosed: @escaping () -> Void) {
        self.model = model
        self.onClosed = onClosed
        let size = OnboardingJourneyView.size
        let window = OnboardingJourneyWindow(
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
        // The onboarding is dark in every appearance, like the island.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.063, alpha: 1)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let hosting = NSHostingController(rootView: OnboardingJourneyView(model: model))
        // The page fills the whole window, title bar included.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingJourneyWindowController only supports programmatic init.")
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        guard let window else { return }
        SidekeyWindowChrome.centerOnMainScreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installBackKey()
    }

    /// ← and ⌘[ go back a step while this window has the keyboard and no
    /// text field does (`OnboardingBackKey`).
    private func installBackKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  OnboardingBackKey.isBack(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                           editingText: OnboardingBackKey.isEditingText(window.firstResponder)),
                  self.model.canGoBack else { return event }
            self.model.back()
            return nil
        }
    }

    /// The window passes key presses it does not take up to its controller,
    /// the end of the responder chain, where AppKit would beep.
    override func noResponder(for eventSelector: Selector) {
        if let window = window as? OnboardingJourneyWindow, window.silences(eventSelector) { return }
        super.noResponder(for: eventSelector)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.stop()
        onClosed()
    }
}

/// The onboarding's window. A key press nothing in it takes (Space, a letter,
/// Escape or an unbound ⌘ shortcut on a step without a text field, or while
/// the Try Drop field is not yet focused) ends here, and `NSWindow` answers
/// it with the system alert sound. Most onboarding steps have no text field,
/// so those sounds came with no visible cause; they are dropped silently.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
final class OnboardingJourneyWindow: NSWindow {
    /// Key presses dropped here instead of beeping (for tests).
    private(set) var silencedKeyPresses = 0

    override func noResponder(for eventSelector: Selector) {
        if silences(eventSelector) { return }
        super.noResponder(for: eventSelector)
    }

    /// `true` for a key press, counted; the caller then stays silent.
    func silences(_ eventSelector: Selector) -> Bool {
        guard eventSelector == #selector(NSResponder.keyDown(with:)) else { return false }
        silencedKeyPresses += 1
        return true
    }
}
