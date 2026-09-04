import AppKit
import SwiftUI

/// Thin window controller for the standalone permission-repair surface.
/// Shown to a returning user when Accessibility and/or Microphone has
/// been revoked. Polls for permission changes every second (since
/// Accessibility is granted externally in System Settings) and
/// auto-closes once all required permissions are granted.
@MainActor
final class PermissionRepairWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: OnboardingPermissionsViewModel
    private var pollTimer: Timer?

    init(onComplete: @escaping () -> Void) {
        let viewModel = OnboardingPermissionsViewModel(onComplete: onComplete, autoComplete: true)
        self.viewModel = viewModel

        let hosting = NSHostingController(
            rootView: PermissionRepairView(viewModel: viewModel)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Whytap"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.appearance = NSAppearance(named: .darkAqua)
        SidekeyWindowChrome.configure(window)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("PermissionRepairWindowController only supports programmatic init.")
    }

    func show() {
        guard let window else { return }
        SidekeyWindowChrome.centerOnMainScreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    override func close() {
        stopPolling()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    // MARK: - Polling

    /// Polls every second to detect Accessibility grants made in System Settings
    /// (outside the app). The view-model's `completeIfReady` fires onComplete
    /// once `snapshot.allRequiredGranted` becomes true.
    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.viewModel.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
