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
        XCTAssertEqual(cursorViews(in: host), 3, "no update: only the Whytap, Help and GitHub links")

        controller.handleDiscovered(version: "2.2.27", build: "2000")
        layout()
        XCTAssertEqual(cursorViews(in: host), 4, "the three links and enabled Update")

        controller.updateFromSettings()
        layout()
        XCTAssertEqual(controller.settingsOffer?.action, .downloading)
        XCTAssertEqual(cursorViews(in: host), 3, "disabled Updating… has no pointing hand")

        AppState.shared.screenshotActive = true
        controller.applyDriverStage(.readyToInstall)
        layout()
        XCTAssertEqual(controller.settingsOffer?.action, .restart)
        XCTAssertEqual(cursorViews(in: host), 4, "enabled Restart has the pointing hand again")
    }
    /// The three links sit one per row in the narrow sidebar, left-aligned and
    /// wide enough for their whole labels (a row of three truncated "Whytap"
    /// and "GitHub"). Set WHYTAP_FOOTER_SNAPSHOT to a path to also write a PNG.
    func test_linksAreStackedVerticallyWithFullLabels() throws {
        let host = NSHostingView(rootView: SettingsProjectFooter(identity: .current)
            .frame(width: 200).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        func cursorFrames(in view: NSView) -> [NSRect] {
            var found: [NSRect] = []
            if String(reflecting: type(of: view)).hasSuffix("SettingsFooterLinkCursor.CursorView"), !view.bounds.isEmpty {
                found.append(host.convert(view.bounds, from: view))
            }
            return found + view.subviews.flatMap { cursorFrames(in: $0) }
        }
        let rows = cursorFrames(in: host).sorted { $0.maxY > $1.maxY }
        XCTAssertEqual(rows.count, 3, "Whytap, Help and GitHub")
        for row in rows {
            XCTAssertEqual(row.minX, rows[0].minX, accuracy: 0.5, "left-aligned")
            XCTAssertGreaterThan(row.width, 90, "room for the icon and the whole label")
        }
        for (upper, lower) in zip(rows, rows.dropFirst()) {
            XCTAssertGreaterThanOrEqual(upper.minY, lower.maxY - 0.5, "one link per row, no overlap")
        }

        if let path = ProcessInfo.processInfo.environment["WHYTAP_FOOTER_SNAPSHOT"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
