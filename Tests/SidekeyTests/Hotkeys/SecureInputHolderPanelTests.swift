import AppKit
import XCTest
@testable import Sidekey

/// The badge window while it is up: the Settings screenshot-protection
/// switch and a change of the island's display reach it live. The test
/// window guard keeps it off screen.
@MainActor
final class SecureInputHolderPanelTests: XCTestCase {
    private let badge = SecureInputHolderBadge(app: SecureInputApp(pid: 999_999, name: "Dia", bundleID: nil))

    override func tearDown() {
        let panel = SecureInputHolderPanel.shared
        panel.dismiss()
        panel.orderOut(nil)
        super.tearDown()
    }

    func testScreenshotProtectionReachesAVisibleBadge() {
        let panel = SecureInputHolderPanel.shared
        panel.present(badge, shake: false, persistent: true)
        XCTAssertTrue(panel.isShowing)

        SecureInputHolderPanel.setScreenshotProtectionEnabled(true)
        XCTAssertEqual(panel.sharingType, .none)
        SecureInputHolderPanel.setScreenshotProtectionEnabled(false)
        XCTAssertEqual(panel.sharingType, .readOnly)
    }

    /// AppKit rounds a window's origin to whole pixels.
    private func assertAnchored(_ frame: NSRect, _ expected: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.size, expected.size, file: file, line: line)
    }

    func testVisibleBadgeFollowsTheIslandsDisplay() {
        let panel = SecureInputHolderPanel.shared
        panel.present(badge, shake: false, persistent: true)
        let screen = IslandScreenResolver.currentDescriptor()
        let expected = SecureInputHolderPanel.frame(on: screen, width: SecureInputHolderPanel.islandHeight(on: screen))
        assertAnchored(panel.frame, expected)

        panel.setFrame(expected.offsetBy(dx: -500, dy: -300), display: false) // stale anchor
        NotificationCenter.default.post(name: IslandScreenResolver.selectionDidChangeNotification, object: nil)
        assertAnchored(panel.frame, expected)

        panel.setFrame(expected.offsetBy(dx: 200, dy: -100), display: false)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        assertAnchored(panel.frame, expected)
    }

    func testWindowIsExactlyThePillSoMenuBarClicksBesideItPassThrough() {
        let panel = SecureInputHolderPanel.shared
        panel.present(badge, shake: false, persistent: true)
        let height = SecureInputHolderPanel.islandHeight(on: IslandScreenResolver.currentDescriptor())
        XCTAssertEqual(panel.frame.width, height, "collapsed: a circle")
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertGreaterThan(SecureInputHolderMetrics.pillWidth(label: badge.label, height: height), height * 4,
                             "on hover it grows to fit the one-line label")
    }

    func testDismissLeavesNothingShowing() {
        let panel = SecureInputHolderPanel.shared
        panel.present(badge, shake: false, persistent: false)
        panel.dismiss()
        XCTAssertFalse(panel.isShowing)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }
}
