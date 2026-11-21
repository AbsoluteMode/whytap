import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen checks of the Settings footer's update button. The window is
/// never ordered front.
@MainActor
final class SettingsProjectFooterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        AppState.shared.updateAvailable = nil
        AppState.shared.screenshotActive = false
    }

    override func tearDown() {
        AppState.shared.updateAvailable = nil
        AppState.shared.screenshotActive = false
        super.tearDown()
    }

    func test_onlyEnabledFooterActionsShowAPointingHand() {
        let controller = UpdateController(appState: .shared, updatesEnabled: false,
                                          downloadAction: {}, installAction: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsProjectFooter(identity: .current, updateController: controller))
        window.contentView = host
        defer { window.contentView = nil }

        func cursorViews(in view: NSView) -> Int {
            let own = String(reflecting: type(of: view)).hasSuffix("SettingsFooterLinkCursor.CursorView")
                && !view.bounds.isEmpty ? 1 : 0
            return own + view.subviews.reduce(0) { $0 + cursorViews(in: $1) }
        }
        func layout() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }

        layout()
        XCTAssertEqual(cursorViews(in: host), 2, "no update: only the Whytap and GitHub links")

        controller.handleDiscovered(version: "2.2.27", build: "2000")
        layout()
        XCTAssertEqual(cursorViews(in: host), 3, "the two links and enabled Update")

        controller.updateFromSettings()
        layout()
        XCTAssertEqual(controller.settingsOffer?.action, .downloading)
        XCTAssertEqual(cursorViews(in: host), 2, "disabled Updating… has no pointing hand")

        AppState.shared.screenshotActive = true
        controller.applyDriverStage(.readyToInstall)
        layout()
        XCTAssertEqual(controller.settingsOffer?.action, .restart)
        XCTAssertEqual(cursorViews(in: host), 3, "enabled Restart has the pointing hand again")
    }
}
