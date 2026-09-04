import AppKit
import SwiftUI

/// Owns the History `NSWindow`. Reuses the same window across menu-bar
/// activations — `show()` brings the existing one to front instead of
/// creating a new one each time the user clicks "History…".
@MainActor
final class HistoryWindowController: NSWindowController {
    private let viewModel: HistoryViewModel

    init(store: any HistoryStore) {
        self.viewModel = HistoryViewModel(store: store)

        let hosting = NSHostingController(rootView: HistoryView(viewModel: viewModel))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whytap History"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("HistoryWindowController only supports programmatic init.")
    }

    /// Bring the window to front and refresh the contents from disk so a
    /// fresh open after a recent paste shows the new row immediately.
    func show() {
        viewModel.refresh()
        if let window {
            SidekeyWindowChrome.centerOnMainScreen(window)
            window.makeKeyAndOrderFront(nil)
            SidekeyWindowChrome.centerOnMainScreen(window)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
